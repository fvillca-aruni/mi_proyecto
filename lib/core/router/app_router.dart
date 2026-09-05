import 'package:go_router/go_router.dart';
import '../widgets/placeholder_screen.dart';

/// Rutas de la aplicación. Cada módulo documentado en el marco teórico
/// tiene aquí su ruta correspondiente, aunque hoy apunten a un placeholder.
final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => const PlaceholderScreen(title: 'Inicio'),
    ),
    GoRoute(
      path: '/auth',
      name: 'auth',
      builder: (context, state) => const PlaceholderScreen(title: 'Cuenta'),
    ),
    GoRoute(
      path: '/education',
      name: 'education',
      builder: (context, state) => const PlaceholderScreen(title: 'Contenido educativo'),
    ),
    GoRoute(
      path: '/reminders',
      name: 'reminders',
      builder: (context, state) => const PlaceholderScreen(title: 'Recordatorios'),
    ),
    GoRoute(
      path: '/exercises',
      name: 'exercises',
      builder: (context, state) => const PlaceholderScreen(title: 'Ejercicios guiados'),
    ),
    GoRoute(
      path: '/stats',
      name: 'stats',
      builder: (context, state) => const PlaceholderScreen(title: 'Estadísticas'),
    ),
  ],
);