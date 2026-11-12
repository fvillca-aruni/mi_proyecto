import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// Inicializa Supabase una sola vez, antes de runApp.
Future<void> initSupabase() async {
  Env.validate();
  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabaseAnonKey,
  );
}

/// Único punto de acceso al cliente. Los repositorios lo reciben por
/// Riverpod; ninguna pantalla debe llamar a Supabase directamente.
final supabaseClientProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);