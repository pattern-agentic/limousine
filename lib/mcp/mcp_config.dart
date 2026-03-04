class McpConfig {
  final bool enabled;
  final int port;
  final String? token;

  McpConfig({this.enabled = false, this.port = 6891, this.token});

  factory McpConfig.fromJson(Map<String, dynamic> json) {
    return McpConfig(
      enabled: json['enabled'] ?? false,
      port: json['port'] ?? 6891,
      token: json['token'],
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'port': port,
    if (token != null && token!.isNotEmpty) 'token': token,
  };

  McpConfig copyWith({bool? enabled, int? port, String? token, bool clearToken = false}) {
    return McpConfig(
      enabled: enabled ?? this.enabled,
      port: port ?? this.port,
      token: clearToken ? null : (token ?? this.token),
    );
  }
}
