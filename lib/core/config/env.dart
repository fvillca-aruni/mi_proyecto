/// Variables de entorno inyectadas en compilación con
/// --dart-define-from-file. Nunca se escriben claves en el código.
class Env {
  Env._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Falla temprano y con mensaje claro si falta configuración.
  static void validate() {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      throw StateError(
        'Faltan SUPABASE_URL o SUPABASE_ANON_KEY. '
        'Ejecuta con --dart-define-from-file=env/dev.json',
      );
    }
  }
}