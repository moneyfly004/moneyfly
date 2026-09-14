#!/usr/bin/env ruby
# frozen_string_literal: true

# 为 moneyfly 的 iOS 工程创建 / 修复 PacketTunnel 扩展 target。
#
# 为什么用脚本而不是手点 Xcode：pbxproj 是结构化文件，脚本化后
# 可重复执行、可 review、CI 与本地一致（幂等：重复运行会先移除旧 target）。
#
# 用法： ruby tool/ios_setup_tunnel_target.rb
# 前置： ios/Mihomelib.xcframework 已就位（bash tool/fetch_mihomo_ios.sh）
require 'xcodeproj'

PROJECT = 'ios/Runner.xcodeproj'
TARGET_NAME = 'PacketTunnel'
BUNDLE_ID = 'top.moneyfly.app.tunnel'
DEPLOYMENT_TARGET = '14.0'
FRAMEWORK = 'Mihomelib.xcframework'

unless File.exist?(PROJECT)
  abort "✗ 未找到 #{PROJECT}（先执行 flutter create --platforms=ios .）"
end

project = Xcodeproj::Project.open(PROJECT)
runner = project.targets.find { |t| t.name == 'Runner' }
abort '✗ 未找到 Runner target' unless runner

# ---- 幂等：移除已存在的扩展 target ----
project.targets.select { |t| t.name == TARGET_NAME }.each do |old|
  old.build_configurations.each { |c| c.remove_from_project }
  old.product_reference&.remove_from_project
  old.remove_from_project
  puts "· 移除旧的 #{TARGET_NAME} target"
end

# ---- 创建 app extension target ----
target = project.new_target(:app_extension, TARGET_NAME, :ios, DEPLOYMENT_TARGET)

# ---- 源码 ----
group = project.main_group.find_subpath(TARGET_NAME, true)
group.set_source_tree('<group>')
group.set_path(TARGET_NAME)
src = group.new_file('PacketTunnelProvider.swift')
target.add_file_references([src])

# ---- 构建配置 ----
target.build_configurations.each do |config|
  bs = config.build_settings
  bs['INFOPLIST_FILE'] = "#{TARGET_NAME}/Info.plist"
  bs['CODE_SIGN_ENTITLEMENTS'] = "#{TARGET_NAME}/#{TARGET_NAME}.entitlements"
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  bs['PRODUCT_NAME'] = '$(TARGET_NAME)'
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  bs['SWIFT_VERSION'] = '5.0'
  bs['TARGETED_DEVICE_FAMILY'] = '1,2'
  bs['SKIP_INSTALL'] = 'YES'
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  bs['CLANG_ENABLE_MODULES'] = 'YES'
  bs['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  # gomobile 产出的静态框架是 Objective-C++，需要 libc++；DNS 解析需要 libresolv
  bs['OTHER_LDFLAGS'] = '$(inherited) -lc++ -lresolv'
end

# ---- 链接 mihomo（gomobile 静态 xcframework）----
if File.exist?("ios/#{FRAMEWORK}")
  fw_ref = project.main_group.files.find { |f| f.path == FRAMEWORK } ||
           project.main_group.new_file(FRAMEWORK)
  fw_ref.last_known_file_type = 'wrapper.xcframework'
  target.frameworks_build_phase.add_file_reference(fw_ref) unless
    target.frameworks_build_phase.files_references.include?(fw_ref)
  puts "· 已链接 #{FRAMEWORK}"
else
  warn "⚠ 未找到 ios/#{FRAMEWORK}：扩展会以「未包含内核」的错误路径编译。" \
       '先运行 bash tool/fetch_mihomo_ios.sh'
end

# ---- 把 geo 分流数据塞进扩展 bundle ----
# 用 Run Script 而不是直接引用文件：assets/rules/ 是构建期下载的，
# 不提交进仓库，直接引用会让缺文件时工程本身无法打开/构建。
phase_name = 'Copy geo data'
target.build_phases.reject { |p| p.respond_to?(:name) && p.name == phase_name }.each { |_| }
existing = target.build_phases.find { |p| p.respond_to?(:name) && p.name == phase_name }
existing&.remove_from_project
script_phase = target.new_shell_script_build_phase(phase_name)
# geo 是构建期产物，脚本必须每次执行（否则 Xcode 会因无输出依赖而告警）
script_phase.always_out_of_date = '1'
script_phase.shell_script = <<~SH
  set -e
  SRC="$SRCROOT/../assets/rules"
  DEST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  mkdir -p "$DEST"
  for f in country.mmdb geosite.dat; do
    if [ -f "$SRC/$f" ]; then
      cp -f "$SRC/$f" "$DEST/$f"
    elif [ "$CONFIGURATION" = "Release" ]; then
      echo "error: 缺少 $SRC/$f（iOS 分流数据必须随包分发）" >&2
      exit 1
    else
      echo "warning: 缺少 $SRC/$f（Debug 构建继续，分流规则将降级）"
    fi
  done
SH

# ---- Runner 依赖 + 嵌入 PlugIns ----
runner.add_dependency(target) unless runner.dependencies.any? { |d| d.target == target }
embed = runner.build_phases.find do |p|
  p.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) &&
    p.name == 'Embed App Extensions'
end
if embed.nil?
  embed = runner.new_copy_files_build_phase('Embed App Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
end
embed.add_file_reference(target.product_reference) unless
  embed.files_references.include?(target.product_reference)
embed.files.find { |f| f.file_ref == target.product_reference }
     &.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# ---- Runner 签名 entitlements ----
runner.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# Runner 需要知道扩展的 bundle id（App 侧用它筛选 VPN 配置）
runner.build_configurations.each do |config|
  config.build_settings['MONEYFLY_TUNNEL_BUNDLE_ID'] = BUNDLE_ID
end

project.save
puts "✓ 已生成 #{TARGET_NAME} target（bundle id: #{BUNDLE_ID}）"
