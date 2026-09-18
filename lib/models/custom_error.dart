class CustomError implements Exception {
  final String code;
  final String message;
  final String plugin;

  const CustomError({
    this.code = '',
    this.message = '',
    this.plugin = '',
  });

  @override
  String toString() => 'CustomError(code: $code, message: $message, plugin: $plugin)';
}
