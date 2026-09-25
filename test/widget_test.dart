import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_umbral/main.dart';

void main() {
  testWidgets('La app carga correctamente', (WidgetTester tester) async {
    // Construye la app principal
    await tester.pumpWidget(const TaskApp());

    // Verifica que aparezca el título del AppBar
    expect(find.text('Umbral: Tu Gestor de Tareas'), findsOneWidget);

    // Verifica que exista el botón flotante de agregar tarea
    expect(find.byIcon(Icons.add), findsOneWidget);
  });
}
