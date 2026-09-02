/// 数据模型（与 myweb 后端字段逐一对齐）
library;

// ============ 用户 ============
class UserInfo {
  final int id;
  final String username;
  final String email;
  final double balance;
  final bool isAdmin;

  UserInfo({
    required this.id,
    required this.username,
    required this.email,
    required this.balance,
    this.isAdmin = false,
  });

  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        username: j['username']?.toString() ?? '',
        email: j['email']?.toString() ?? '',
        balance: double.tryParse(j['balance']?.toString() ?? '') ?? (j['balance'] as num?)?.toDouble() ?? 0,
        isAdmin: j['is_admin'] == true,
      );
}

/// /users/dashboard-info 返回（我的页数据源）
class DashboardInfo {
  final String username;
  final String email;
  final double balance;
  final String membership;
  final int onlineDevices;
  final int totalDevices;
  final String subscriptionStatus;
  final String expireTime;
  final int remainingDays;
  final bool hasSpecialNodes;

  DashboardInfo({
    required this.username,
    required this.email,
    required this.balance,
    required this.membership,
    required this.onlineDevices,
    required this.totalDevices,
    required this.subscriptionStatus,
    required this.expireTime,
    required this.remainingDays,
    required this.hasSpecialNodes,
  });

  factory DashboardInfo.fromJson(Map<String, dynamic> j) => DashboardInfo(
        username: j['username']?.toString() ?? '',
        email: j['email']?.toString() ?? '',
        balance: double.tryParse(j['balance']?.toString() ?? '') ?? 0,
        membership: j['membership']?.toString() ?? '',
        onlineDevices: (j['online_devices'] as num?)?.toInt() ?? 0,
        totalDevices: (j['total_devices'] as num?)?.toInt() ?? 0,
        subscriptionStatus: j['subscription_status']?.toString() ?? '',
        expireTime: j['expire_time']?.toString() ?? '未设置',
        remainingDays: (j['remaining_days'] as num?)?.toInt() ?? 0,
        hasSpecialNodes: j['has_special_nodes'] == true,
      );

  bool get hasSubscription => subscriptionStatus.isNotEmpty && subscriptionStatus != 'inactive';
}

// ============ 订阅 ============
/// /user/subscribe（XBoard 兼容）
class SubscriptionInfo {
  final String subscribeUrl;
  final String? universalUrl;
  final DateTime? expireTime;
  final int deviceLimit;
  final int currentDevices;
  final int remainingDays;
  final bool isExpired;
  final String status;

  SubscriptionInfo({
    required this.subscribeUrl,
    this.universalUrl,
    this.expireTime,
    required this.deviceLimit,
    required this.currentDevices,
    required this.remainingDays,
    required this.isExpired,
    required this.status,
  });

  factory SubscriptionInfo.fromJson(Map<String, dynamic> j) {
    final et = j['expire_time']?.toString();
    return SubscriptionInfo(
      subscribeUrl: j['subscribe_url']?.toString() ?? '',
      universalUrl: j['universal_url']?.toString(),
      expireTime: (et == null || et.isEmpty) ? null : DateTime.tryParse(et),
      deviceLimit: (j['device_limit'] as num?)?.toInt() ?? 0,
      currentDevices: (j['current_devices'] as num?)?.toInt() ?? 0,
      remainingDays: (j['remaining_days'] as num?)?.toInt() ?? 0,
      isExpired: j['is_expired'] == true,
      status: j['status']?.toString() ?? '',
    );
  }

  bool get hasSubscription => subscribeUrl.isNotEmpty && !isExpired;
}

// ============ 套餐 / 支付 ============
class Plan {
  final int id;
  final String name;
  final String? description;
  final double price;
  final int durationDays;
  final int deviceLimit;
  final bool isRecommended;

  Plan({
    required this.id,
    required this.name,
    this.description,
    required this.price,
    required this.durationDays,
    required this.deviceLimit,
    required this.isRecommended,
  });

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name']?.toString() ?? '',
        description: j['description']?.toString(),
        price: (j['price'] as num?)?.toDouble() ?? 0,
        durationDays: (j['duration_days'] as num?)?.toInt() ?? 0,
        deviceLimit: (j['device_limit'] as num?)?.toInt() ?? 0,
        isRecommended: j['is_recommended'] == true,
      );
}

class PayMethod {
  final int id;
  final String payType;
  final String name;
  final int sortOrder;

  PayMethod({required this.id, required this.payType, required this.name, required this.sortOrder});

  factory PayMethod.fromJson(Map<String, dynamic> j) => PayMethod(
        id: (j['id'] as num?)?.toInt() ?? 0,
        // 实测后端返回字段为 key（如 alipay / wechat / yipay_alipay / usdt），
        // 兼容历史 pay_type 字段
        payType: j['key']?.toString() ?? j['pay_type']?.toString() ?? '',
        name: j['name']?.toString() ?? j['key']?.toString() ?? '',
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );

  bool get isAlipay => payType.contains('alipay');
  bool get isWechat => payType.contains('wechat') || payType.contains('wxpay');
  bool get isCrypto => payType.contains('usdt') || payType.contains('crypto');
}

class PaymentResult {
  final String qrCode;
  final String orderNo;
  final String status;

  PaymentResult({required this.qrCode, required this.orderNo, required this.status});

  factory PaymentResult.fromJson(Map<String, dynamic> j) => PaymentResult(
        qrCode: j['payment_qr_code']?.toString() ?? j['qrcode']?.toString() ?? '',
        orderNo: j['order_no']?.toString() ?? j['orderNo']?.toString() ?? '',
        status: j['status']?.toString() ?? 'pending',
      );
}

// ============ 订单 ============
class OrderItem {
  final int id;
  final String orderNo;
  final double amount;
  final double finalAmount;
  final String status;
  final String type;
  final String? packageName;
  final String? paymentMethodName;
  final String createdAt;

  OrderItem({
    required this.id,
    required this.orderNo,
    required this.amount,
    required this.finalAmount,
    required this.status,
    required this.type,
    this.packageName,
    this.paymentMethodName,
    required this.createdAt,
  });

  factory OrderItem.fromJson(Map<String, dynamic> j) {
    final orderData = j['order'] is Map ? j['order'] as Map : j;
    final packageData = j['package'] is Map ? j['package'] as Map : null;
    return OrderItem(
      id: (orderData['id'] as num?)?.toInt() ?? (j['id'] as num?)?.toInt() ?? 0,
      orderNo: orderData['order_no']?.toString() ?? j['order_no']?.toString() ?? '',
      amount: (orderData['amount'] as num?)?.toDouble() ?? (j['amount'] as num?)?.toDouble() ?? 0,
      finalAmount: (orderData['final_amount'] as num?)?.toDouble() ?? 0,
      status: orderData['status']?.toString() ?? j['status']?.toString() ?? '',
      type: orderData['type']?.toString() ?? 'order',
      packageName: packageData?['name']?.toString() ?? j['package_name']?.toString(),
      paymentMethodName: j['payment_method_name']?.toString() ?? orderData['payment_method_name']?.toString(),
      createdAt: j['created_at']?.toString() ?? orderData['created_at']?.toString() ?? '',
    );
  }

  String get statusLabel => switch (status) {
        'pending' => '待支付',
        'paid' => '已支付',
        'cancelled' => '已取消',
        'expired' => '已过期',
        'failed' => '失败',
        _ => status,
      };
}

/// 订单状态查询结果
class OrderStatus {
  final String orderNo;
  final String status;
  final double amount;
  final double finalAmount;
  final String type;

  OrderStatus({
    required this.orderNo,
    required this.status,
    required this.amount,
    required this.finalAmount,
    required this.type,
  });

  factory OrderStatus.fromJson(Map<String, dynamic> j) => OrderStatus(
        orderNo: j['order_no']?.toString() ?? j['orderNo']?.toString() ?? '',
        status: j['status']?.toString() ?? 'pending',
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        finalAmount: (j['final_amount'] as num?)?.toDouble() ?? 0,
        type: j['type']?.toString() ?? 'order',
      );

  bool get isPaid => status == 'paid';
}

// ============ 设备 ============
class DeviceInfo {
  final int id;
  final int? subscriptionId;
  final String deviceName;
  final String deviceType;
  final String deviceModel;
  final String deviceBrand;
  final String ipAddress;
  final String location;
  final String osName;
  final String osVersion;
  final String softwareName;
  final String softwareVersion;
  final bool isActive;
  final bool isAllowed;
  final String lastSeen;
  final String lastAccess;
  final String firstSeen;
  final int accessCount;
  final String remark;

  DeviceInfo({
    required this.id,
    this.subscriptionId,
    required this.deviceName,
    required this.deviceType,
    required this.deviceModel,
    required this.deviceBrand,
    required this.ipAddress,
    required this.location,
    required this.osName,
    required this.osVersion,
    required this.softwareName,
    required this.softwareVersion,
    required this.isActive,
    required this.isAllowed,
    required this.lastSeen,
    required this.lastAccess,
    required this.firstSeen,
    required this.accessCount,
    required this.remark,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        subscriptionId: (j['subscription_id'] as num?)?.toInt(),
        // /subscriptions/devices 有 name/ip/type 冗余别名
        deviceName: j['device_name']?.toString() ?? j['name']?.toString() ?? '',
        deviceType: j['device_type']?.toString() ?? j['type']?.toString() ?? '',
        deviceModel: j['device_model']?.toString() ?? '',
        deviceBrand: j['device_brand']?.toString() ?? '',
        ipAddress: j['ip_address']?.toString() ?? j['ip']?.toString() ?? '',
        location: j['location']?.toString() ?? '',
        osName: j['os_name']?.toString() ?? '',
        osVersion: j['os_version']?.toString() ?? '',
        softwareName: j['software_name']?.toString() ?? '',
        softwareVersion: j['software_version']?.toString() ?? '',
        isActive: j['is_active'] == true,
        isAllowed: j['is_allowed'] == true,
        lastSeen: j['last_seen']?.toString() ?? '',
        lastAccess: j['last_access']?.toString() ?? '',
        firstSeen: j['first_seen']?.toString() ?? '',
        accessCount: (j['access_count'] as num?)?.toInt() ?? 0,
        remark: j['remark']?.toString() ?? '',
      );

  String get displayName => deviceName.isNotEmpty ? deviceName : (osName.isNotEmpty ? osName : '未知设备');
}

// ============ 通知 ============
class AppNotification {
  final int id;
  final String title;
  final String content;
  final String type;
  final bool isRead;
  final String createdAt;

  AppNotification({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: (j['id'] as num?)?.toInt() ?? 0,
        title: j['title']?.toString() ?? '',
        content: j['content']?.toString() ?? '',
        type: j['type']?.toString() ?? 'system',
        isRead: j['is_read'] == true,
        createdAt: j['created_at']?.toString() ?? '',
      );
}

// ============ 优惠券 ============
class Coupon {
  final int id;
  final String code;
  final String name;
  final String discountType;
  final double discountValue;
  final double minAmount;
  final String? expireTime;
  final bool isActive;

  Coupon({
    required this.id,
    required this.code,
    required this.name,
    required this.discountType,
    required this.discountValue,
    required this.minAmount,
    this.expireTime,
    required this.isActive,
  });

  factory Coupon.fromJson(Map<String, dynamic> j) => Coupon(
        id: (j['id'] as num?)?.toInt() ?? 0,
        code: j['code']?.toString() ?? '',
        name: j['name']?.toString() ?? j['code']?.toString() ?? '',
        discountType: j['discount_type']?.toString() ?? 'percent',
        discountValue: (j['discount_value'] as num?)?.toDouble() ?? 0,
        minAmount: (j['min_amount'] as num?)?.toDouble() ?? 0,
        expireTime: j['expire_time']?.toString(),
        isActive: j['is_active'] != false,
      );

  /// 计算折后金额
  double applyTo(double amount) {
    if (discountType == 'fixed') return (amount - discountValue).clamp(0.01, amount);
    return (amount * (1 - discountValue / 100)).clamp(0.01, amount);
  }
}

// ============ 节点（Clash 订阅解析结果） ============
class ProxyNode {
  final String tag;
  final String type;
  final String server;
  final int port;
  final String? region;
  final String? countryCode;
  final String? uuid;
  final String? cipher;
  final String? password;
  final bool? tls;
  final String? sni;
  final String? network;
  final String? wsPath;
  final String? host;
  final String? flow;
  final Map<String, dynamic> raw;
  int latencyMs; // -1 未测
  bool online;

  ProxyNode({
    required this.tag,
    required this.type,
    required this.server,
    required this.port,
    this.region,
    this.countryCode,
    this.uuid,
    this.cipher,
    this.password,
    this.tls,
    this.sni,
    this.network,
    this.wsPath,
    this.host,
    this.flow,
    Map<String, dynamic>? raw,
    this.latencyMs = -1,
    this.online = true,
  }) : raw = raw ?? {};

  static const countryNames = {
    'HK': '香港', 'TW': '台湾', 'JP': '日本', 'SG': '新加坡', 'KR': '韩国',
    'US': '美国', 'GB': '英国', 'DE': '德国', 'FR': '法国', 'AU': '澳大利亚',
    'CA': '加拿大', 'RU': '俄罗斯', 'IN': '印度', 'TH': '泰国', 'VN': '越南',
    'NL': '荷兰', 'SE': '瑞典', 'FI': '芬兰', 'CH': '瑞士', 'AE': '阿联酋',
    'PH': '菲律宾', 'MY': '马来西亚', 'ID': '印尼', 'TR': '土耳其',
    'BR': '巴西', 'AR': '阿根廷', 'IE': '爱尔兰', 'PL': '波兰',
    'IT': '意大利', 'ES': '西班牙', 'PT': '葡萄牙', 'MX': '墨西哥',
    'CL': '智利', 'ZA': '南非', 'KZ': '哈萨克斯坦', 'UA': '乌克兰',
  };

  static const countryFlags = {
    'HK': '\u{1F1ED}\u{1F1F0}', 'TW': '\u{1F1F9}\u{1F1FC}', 'JP': '\u{1F1EF}\u{1F1F5}',
    'SG': '\u{1F1F8}\u{1F1EC}', 'KR': '\u{1F1F0}\u{1F1F7}', 'US': '\u{1F1FA}\u{1F1F8}',
    'GB': '\u{1F1EC}\u{1F1E7}', 'DE': '\u{1F1E9}\u{1F1EA}', 'FR': '\u{1F1EB}\u{1F1F7}',
    'AU': '\u{1F1E6}\u{1F1FA}', 'CA': '\u{1F1E8}\u{1F1E6}', 'RU': '\u{1F1F7}\u{1F1FA}',
    'IN': '\u{1F1EE}\u{1F1F3}', 'TH': '\u{1F1F9}\u{1F1ED}', 'VN': '\u{1F1FB}\u{1F1F3}',
    'NL': '\u{1F1F3}\u{1F1F1}', 'SE': '\u{1F1F8}\u{1F1EA}', 'FI': '\u{1F1EB}\u{1F1EE}',
    'CH': '\u{1F1E8}\u{1F1ED}', 'AE': '\u{1F1E6}\u{1F1EA}', 'PH': '\u{1F1F5}\u{1F1ED}',
    'MY': '\u{1F1F2}\u{1F1FE}', 'ID': '\u{1F1EE}\u{1F1E9}', 'TR': '\u{1F1F9}\u{1F1F7}',
    'BR': '\u{1F1E7}\u{1F1F7}', 'AR': '\u{1F1E6}\u{1F1F7}', 'IE': '\u{1F1EE}\u{1F1EA}',
    'PL': '\u{1F1F5}\u{1F1F1}', 'IT': '\u{1F1EE}\u{1F1F9}', 'ES': '\u{1F1EA}\u{1F1F8}',
    'PT': '\u{1F1F5}\u{1F1F9}', 'MX': '\u{1F1F2}\u{1F1FD}', 'CL': '\u{1F1E8}\u{1F1F1}',
    'ZA': '\u{1F1FF}\u{1F1E6}', 'KZ': '\u{1F1F0}\u{1F1FF}', 'UA': '\u{1F1FA}\u{1F1E6}',
  };

  String get flag => countryFlags[countryCode?.toUpperCase()] ?? '\u{1F310}';

  String get regionName => countryNames[countryCode?.toUpperCase()] ?? '其他';

  /// 由 Clash YAML 节点 map 构造
  factory ProxyNode.fromClashMap(Map<String, dynamic> m) {
    final tag = m['name']?.toString() ?? '未命名节点';
    final server = m['server']?.toString() ?? '';
    final port = (m['port'] as num?)?.toInt() ?? 0;
    final region = m['region']?.toString() ?? m['country']?.toString();
    final countryCode = m['country-code']?.toString() ?? _inferCountry(tag, region);
    return ProxyNode(
      tag: tag,
      type: m['type']?.toString() ?? 'vless',
      server: server,
      port: port,
      region: region,
      countryCode: countryCode,
      uuid: m['uuid']?.toString(),
      cipher: m['cipher']?.toString(),
      password: m['password']?.toString(),
      tls: m['tls'] == true,
      sni: m['servername']?.toString() ?? m['sni']?.toString(),
      network: m['network']?.toString(),
      wsPath: m['ws-opts'] is Map ? (m['ws-opts'] as Map)['path']?.toString() : null,
      host: m['ws-opts'] is Map && (m['ws-opts'] as Map)['headers'] is Map
          ? ((m['ws-opts'] as Map)['headers'] as Map)['Host']?.toString()
          : null,
      flow: m['flow']?.toString(),
      raw: Map<String, dynamic>.from(m),
    );
  }

  static String _inferCountry(String tag, String? region) {
    final upper = '$tag $region'.toUpperCase();
    const map = {
      '香港': 'HK', 'HONGKONG': 'HK', 'HONG KONG': 'HK', 'HK': 'HK',
      '台湾': 'TW', 'TAIWAN': 'TW', '台北': 'TW',
      '日本': 'JP', 'JAPAN': 'JP', 'TOKYO': 'JP', '大阪': 'JP', '东京': 'JP', 'OSAKA': 'JP',
      '新加坡': 'SG', 'SINGAPORE': 'SG',
      '韩国': 'KR', 'KOREA': 'KR', 'SEOUL': 'KR', '首尔': 'KR',
      '美国': 'US', 'USA': 'US', 'UNITED STATES': 'US', 'LOS ANGELES': 'US', 'SEATTLE': 'US', 'SAN JOSE': 'US', 'NEW YORK': 'US', '洛杉矶': 'US', '纽约': 'US', '西雅图': 'US', '硅谷': 'US', 'SILICON': 'US', 'DALLAS': 'US', 'CHICAGO': 'US',
      '英国': 'GB', 'UK': 'GB', 'LONDON': 'GB', 'UNITED KINGDOM': 'GB', '伦敦': 'GB',
      '德国': 'DE', 'GERMANY': 'DE', 'FRANKFURT': 'DE', '法兰克福': 'DE',
      '法国': 'FR', 'FRANCE': 'FR', 'PARIS': 'FR', '巴黎': 'FR',
      '澳大利亚': 'AU', 'AUSTRALIA': 'AU', 'SYDNEY': 'AU', '悉尼': 'AU',
      '加拿大': 'CA', 'CANADA': 'CA', 'TORONTO': 'CA', 'VANCOUVER': 'CA',
      '俄罗斯': 'RU', 'RUSSIA': 'RU', 'MOSCOW': 'RU', '莫斯科': 'RU',
      '印度': 'IN', 'INDIA': 'IN', 'MUMBAI': 'IN', '孟买': 'IN',
      '泰国': 'TH', 'THAILAND': 'TH', 'BANGKOK': 'TH', '曼谷': 'TH',
      '越南': 'VN', 'VIETNAM': 'VN',
      '荷兰': 'NL', 'NETHERLANDS': 'NL', 'AMSTERDAM': 'NL', '阿姆斯特丹': 'NL',
      '阿联酋': 'AE', 'DUBAI': 'AE', 'UAE': 'AE', '迪拜': 'AE',
      '瑞典': 'SE', 'SWEDEN': 'SE',
      '芬兰': 'FI', 'FINLAND': 'FI',
      '瑞士': 'CH', 'SWITZERLAND': 'CH', 'ZURICH': 'CH',
      '菲律宾': 'PH', 'PHILIPPINES': 'PH', 'MANILA': 'PH',
      '马来西亚': 'MY', 'MALAYSIA': 'MY',
      '印尼': 'ID', 'INDONESIA': 'ID', 'JAKARTA': 'ID',
      '土耳其': 'TR', 'TURKEY': 'TR', 'ISTANBUL': 'TR',
      '巴西': 'BR', 'BRAZIL': 'BR', 'SAO PAULO': 'BR',
      '阿根廷': 'AR', 'ARGENTINA': 'AR',
      '爱尔兰': 'IE', 'IRELAND': 'IE', 'DUBLIN': 'IE',
      '波兰': 'PL', 'POLAND': 'PL', 'WARSAW': 'PL',
      '意大利': 'IT', 'ITALY': 'IT', 'MILAN': 'IT',
      '西班牙': 'ES', 'SPAIN': 'ES', 'MADRID': 'ES',
    };
    for (final e in map.entries) {
      if (upper.contains(e.key)) return e.value;
    }
    return 'XX';
  }
}
