// Package mihomelib 是 MoneyFly Android 端的内核封装（gomobile bind 目标包）。
//
// 设计：把官方 MetaCubeX/mihomo（v1.19.30，不作为 fork 改动）当进程内库启动，
// 由 Kotlin VpnService 提供 TUN fd（VpnService.establish()），经 tun.file-descriptor
// 注入配置，实现非 root 全局代理。外部管理通道走内核自带 Clash API
// （external-controller，与桌面端完全一致），Flutter 层无需区分平台。
//
// 本目录是独立 Go module（android/mihomo-core/），CI 用 gomobile bind 产出
// libmihomo.aar 供 android/app/libs 集成（见 .github/workflows/release.yml）。
package mihomelib

import (
	"fmt"
	"sync"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"gopkg.in/yaml.v3"
)

var (
	mu      sync.Mutex
	started bool
)

// Version 返回内核版本字符串（如 "v1.19.30"）。
func Version() string {
	return C.Version
}

// Meta 内核是否 Meta 特性构建。
func Meta() bool {
	return C.Meta
}

// Running 内核是否已在运行。
func Running() bool {
	mu.Lock()
	defer mu.Unlock()
	return started
}

// Start 初始化并启动内核（幂等：已在运行时返回错误）。
//
// homeDirArg: 内核工作目录（config.yaml 与 country.mmdb/geosite.dat 所在目录，
// 由调用方保证 geo 数据已就位；mihomo 从该目录按默认文件名加载）。
// configBytes: mihomo Clash YAML 配置（Flutter 侧生成）。
// tunFd: VpnService.establish() 的 TUN fd；>0 时注入 tun.file-descriptor
// （非 root 全局代理的关键：内核直接用该 fd 收发包，不再自己创建 /dev/tun）。
func Start(homeDirArg string, configBytes []byte, tunFd int32) (err error) {
	mu.Lock()
	defer mu.Unlock()
	if started {
		return fmt.Errorf("mihomo already started")
	}
	// go panic 会跨 cgo 边界直接崩掉整个 App —— 防御性恢复，保证连接失败
	// 是「可重试的错误」而不是「闪退」
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("mihomo start panic: %v", r)
		}
	}()
	log.SetLevel(log.WARNING)

	// 初始化 homeDir（config.Init 会建目录与默认文件）
	C.SetHomeDir(homeDirArg)
	if err := config.Init(C.Path.HomeDir()); err != nil {
		return fmt.Errorf("init config dir: %w", err)
	}

	// TUN fd 注入：仅当配置启用了 tun 且调用方提供了有效 fd
	if tunFd > 0 {
		var err error
		configBytes, err = injectTunFd(configBytes, tunFd)
		if err != nil {
			return fmt.Errorf("inject tun fd: %w", err)
		}
	}

	if err := hub.Parse(configBytes); err != nil {
		// 启动失败兜底：清掉可能已半初始化的 listener/tunnel
		executor.Shutdown()
		return fmt.Errorf("parse config: %w", err)
	}
	started = true
	return nil
}

// Reload 热重载配置（模式/规则/订阅变化时调用；不重启进程不断流）。
func Reload(configBytes []byte) (err error) {
	mu.Lock()
	defer mu.Unlock()
	if !started {
		return fmt.Errorf("mihomo not started")
	}
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("mihomo reload panic: %v", r)
		}
	}()
	if err := hub.Parse(configBytes); err != nil {
		return fmt.Errorf("reload config: %w", err)
	}
	return nil
}

// Stop 停止内核并释放资源（TUN/VpnService 由 Kotlin 侧关闭）。
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	if !started {
		return
	}
	executor.Shutdown()
	started = false
}

// injectTunFd 解析 YAML，把 tun.file-descriptor 写入 tun 段。
// 配置里 tun.enable=true 且无 fd 时注入；无 tun 段则不处理。
func injectTunFd(configBytes []byte, tunFd int32) ([]byte, error) {
	var doc map[string]interface{}
	if err := yaml.Unmarshal(configBytes, &doc); err != nil {
		return nil, err
	}
	tun, ok := doc["tun"].(map[string]interface{})
	if !ok {
		// 配置未声明 tun（needTun 由 Kotlin 决定，通常配置已含），保持原样
		return configBytes, nil
	}
	if enable, _ := tun["enable"].(bool); !enable {
		return configBytes, nil
	}
	tun["file-descriptor"] = int(tunFd)
	// Android 场景：VpnService 已全量下发路由(0.0.0.0/0)与地址，
	// 内核不要再尝试 auto-route/探测默认接口（非 root 下会失败/告警）
	tun["auto-route"] = false
	tun["auto-detect-interface"] = false
	out, err := yaml.Marshal(doc)
	if err != nil {
		return nil, err
	}
	return out, nil
}
