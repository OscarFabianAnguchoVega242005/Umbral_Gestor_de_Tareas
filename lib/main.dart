import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

// -----------------------------------------------------------------------------
// 0. FUNCIÓN DE UTILIDAD PARA COLORES
// -----------------------------------------------------------------------------
/// Función de utilidad para crear un MaterialColor a partir de un Color simple.
/// Esto es necesario para la propiedad 'primarySwatch' del ThemeData.
MaterialColor createMaterialColor(Color color) {
  List strengths = <double>[.05];
  Map<int, Color> swatch = {};
  final int r = color.red, g = color.green, b = color.blue;

  for (int i = 1; i < 10; i++) {
    strengths.add(0.1 * i);
  }
  for (var strength in strengths) {
    final double ds = 0.5 - strength;
    swatch[(strength * 1000).round()] = Color.fromRGBO(
      r + ((ds < 0 ? r : (255 - r)) * ds).round(),
      g + ((ds < 0 ? g : (255 - g)) * ds).round(),
      b + ((ds < 0 ? b : (255 - b)) * ds).round(),
      1,
    );
  }
  return MaterialColor(color.value, swatch);
}

// -----------------------------------------------------------------------------
// 1. CONFIGURACIÓN DE NOTIFICACIONES LOCALES
// -----------------------------------------------------------------------------
// Objeto global para manejar las notificaciones.
// FIX: La variable se inicializa directamente para evitar LateInitializationError.
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

/// Inicializa el plugin de notificaciones locales.
Future<void> initializeNotifications() async {
  tz.initializeTimeZones();
  // ⚠️ IMPORTANTE: Ajusta 'America/New_York' a tu zona horaria local.
  // Por ejemplo: 'America/Santiago' o 'Europe/Madrid'.
  tz.setLocalLocation(tz.getLocation('America/New_York'));

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const DarwinInitializationSettings initializationSettingsIOS =
      DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

/// Programa una notificación para una tarea, notificando si vence HOY o MAÑANA.
Future<void> scheduleNotification(
    int id, String title, DateTime dueDate) async {
  final now = tz.TZDateTime.now(tz.local);

  // Convertir la fecha de entrega a TZDateTime, asumiendo la medianoche del día de entrega.
  final dueTime = tz.TZDateTime(
    tz.local,
    dueDate.year,
    dueDate.month,
    dueDate.day,
    23, // 23:59:59 PM del día de entrega
    59,
    59,
  );

  // 1. Comprobar si la fecha límite ya pasó. Si es así, no programar nada.
  if (dueTime.isBefore(now)) {
    return;
  }

  // 2. Determinar la ventana de aviso: Vence hoy o mañana (menos de 48 horas).
  // La notificación se activará 5 segundos después si estamos dentro de la ventana de aviso
  // y la tarea no tiene una notificación programada activa.
  // Usamos la fecha de entrega original (medianoche) menos 48 horas.
  final warningWindowStart = dueTime.subtract(const Duration(hours: 48));

  if (now.isAfter(warningWindowStart)) {
    // 3. Estamos dentro de la ventana de aviso (vence hoy o mañana).
    // Programamos la notificación para AHORA (con 5 segundos de retraso).
    final scheduledDate = now.add(const Duration(seconds: 5));

    // Determinar el mensaje
    String alertMessage =
        'Tu tarea "$title" vence el ${dueDate.day}/${dueDate.month}. ¡Mucha suerte!';
    if (dueDate.difference(now).inDays == 0 && dueDate.day == now.day) {
      alertMessage =
          '¡ENTREGA HOY! Tu tarea "$title" vence al final del día. ¡Corre!';
    } else if (dueDate.difference(now).inDays == 1 && dueDate.day != now.day) {
      alertMessage = '¡ENTREGA MAÑANA! Tu tarea "$title" está a un día del Umbral.';
    }

    print("Aviso de Umbral: Se programará inmediatamente.");

    // Configuraciones específicas de la plataforma
    const notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'tarea_channel_id',
        'Avisos de Tareas Próximas',
        channelDescription: 'Canal para las alertas de tareas próximas.',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    // ⚠️ FIX: Envuelto en try-catch para evitar UnimplementedError en entornos no soportados (como la web/Canvas).
    try {
      await flutterLocalNotificationsPlugin.zonedSchedule(
        id,
        '⏰ ¡ALERTA DE UMBRAL!',
        alertMessage,
        scheduledDate,
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents:
            DateTimeComponents.time, // Usamos time para un aviso inmediato
      );
    } catch (e) {
      print("Error al programar notificación (ignorado en este entorno): $e");
    }
  }
}

// -----------------------------------------------------------------------------
// 2. MODELO DE DATOS CON SERIALIZACIÓN PARA PERSISTENCIA
// -----------------------------------------------------------------------------

/// Enumeración de los posibles estados de una tarea.
enum TaskStatus {
  pendiente,
  enProceso,
  terminada,
}

/// Clase que representa una Tarea.
class Task {
  final int id;
  String title;
  TaskStatus status;
  DateTime? dueDate;

  Task({
    required this.id,
    required this.title,
    this.status = TaskStatus.pendiente,
    this.dueDate,
  });

  /// Convierte el objeto Task a un mapa JSON para guardar.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'status': status.index, // Guardamos el índice del enum (0, 1, 2)
        'dueDate': dueDate?.toIso8601String(), // Guardamos la fecha como string
      };

  /// Crea un objeto Task a partir de un mapa JSON.
  factory Task.fromJson(Map<String, dynamic> json) {
    TaskStatus statusFromIndex(int index) {
      if (index == 0) return TaskStatus.pendiente;
      if (index == 1) return TaskStatus.enProceso;
      return TaskStatus.terminada;
    }

    return Task(
      id: json['id'],
      title: json['title'],
      status: statusFromIndex(json['status'] ?? 0),
      dueDate: json['dueDate'] != null ? DateTime.parse(json['dueDate']) : null,
    );
  }
}

// -----------------------------------------------------------------------------
// 3. WIDGET PRINCIPAL Y ESTADO DE LA APLICACIÓN
// -----------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeNotifications();
  runApp(const TaskApp());
}

class TaskApp extends StatelessWidget {
  const TaskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Umbral - Gestión de Tareas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // 🚨 FIX: Usamos la función de utilidad para crear un MaterialColor a partir de tu color negro.
        primarySwatch: createMaterialColor(const Color.fromARGB(255, 0, 0, 0)),
        useMaterial3: true,
        fontFamily: 'Inter',
        appBarTheme: const AppBarTheme(
          // Cambiamos el color de fondo para que el negro no se "pierda"
          backgroundColor: Color.fromARGB(255, 0, 0, 0),
          foregroundColor: Color.fromARGB(255, 255, 255, 255),
        ),
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  // ⚠️ Lista de tareas INICIA VACÍA por solicitud del usuario
  List<Task> _tasks = [];
  int _nextId = 1;

  @override
  void initState() {
    super.initState();
    _loadTasks(); // Cargar tareas guardadas al iniciar
  }

  /// Carga la lista de tareas desde shared_preferences.
  Future<void> _loadTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final tasksJson = prefs.getStringList('tasks');

    if (tasksJson != null) {
      setState(() {
        _tasks = tasksJson.map((item) => Task.fromJson(json.decode(item))).toList();

        // Asegurar que el nextId sea mayor que el ID más alto de las tareas cargadas
        if (_tasks.isNotEmpty) {
          _nextId = _tasks.map((t) => t.id).reduce((a, b) => a > b ? a : b) + 1;
        } else {
          _nextId = 1;
        }
      });
    }
  }

  /// Guarda la lista de tareas en shared_preferences.
  Future<void> _saveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final tasksJson = _tasks.map((task) => json.encode(task.toJson())).toList();
    await prefs.setStringList('tasks', tasksJson);
  }

  /// Abre un diálogo para agregar o editar una tarea.
  void _openTaskDialog({Task? taskToEdit}) {
    final bool isEditing = taskToEdit != null;
    final TextEditingController titleController =
        TextEditingController(text: taskToEdit?.title ?? '');
    DateTime? selectedDate = taskToEdit?.dueDate;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateInDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Text(isEditing ? 'Editar Tarea' : 'Agregar Nueva Tarea'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: titleController,
                    decoration: InputDecoration(
                      labelText: 'Título de la tarea',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Selector de Fecha
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // 🟢 CORRECCIÓN: Usamos un Flexible para evitar el desbordamiento del texto
                      Flexible(
                        child: Text(
                          selectedDate == null
                              ? 'Sin fecha limite'
                              : 'Entrega: ${selectedDate!.day}/${selectedDate!.month}/${selectedDate!.year}',
                          style: TextStyle(
                              color: selectedDate == null
                                  ? Colors.redAccent
                                  : Colors.black87,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8), // Agregamos un espacio entre el texto y el botón
                      ElevatedButton.icon(
                        onPressed: () async {
                          final DateTime? picked = await showDatePicker(
                            context: context,
                            initialDate: selectedDate ?? DateTime.now(),
                            firstDate: DateTime.now(),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            setStateInDialog(() {
                              selectedDate = picked;
                            });
                          }
                        },
                        icon: const Icon(Icons.calendar_today),
                        label: const Text('Elegir Fecha'),
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          // Ajuste de color para el tema oscuro
                          backgroundColor: Theme.of(context).primaryColor,
                          foregroundColor:
                              const Color.fromARGB(255, 28, 18, 106),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final String newTitle = titleController.text.trim();
                    if (newTitle.isNotEmpty) {
                      if (isEditing) {
                        _editTask(taskToEdit!, newTitle, selectedDate);
                      } else {
                        _addTask(newTitle, selectedDate);
                      }
                      Navigator.of(context).pop();
                    }
                  },
                  child: Text(isEditing ? 'Guardar Cambios' : 'Agregar'),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Lógica para agregar una nueva tarea y guardar.
  void _addTask(String title, DateTime? dueDate) {
    // Crear la tarea primero
    final newTask = Task(id: _nextId++, title: title, dueDate: dueDate);

    // Cambios en UI dentro de setState (rápido, sin await)
    setState(() {
      _tasks.add(newTask);
    });

    // Ejecutar la parte asíncrona sin bloquear el hilo UI
    Future.microtask(() async {
      if (dueDate != null && newTask.status != TaskStatus.terminada) {
        try {
          await scheduleNotification(newTask.id, newTask.title, dueDate);
        } catch (e) {
          print("Error al programar notificación al agregar: $e");
        }
      }
      await _saveTasks(); // Guardar cambios async
    });
  }

  /// Lógica para editar una tarea existente y guardar.
  void _editTask(Task task, String newTitle, DateTime? newDueDate) {
    // Actualizar UI rápidamente
    setState(() {
      task.title = newTitle;
      task.dueDate = newDueDate;
    });

    // Ejecutar las operaciones async fuera del setState para no bloquear UI
    Future.microtask(() async {
      try {
        await flutterLocalNotificationsPlugin.cancel(task.id);
      } catch (e) {
        print("Error al cancelar notificación al editar: $e");
      }

      // Solo programar si la tarea NO está terminada
      if (newDueDate != null && task.status != TaskStatus.terminada) {
        try {
          await scheduleNotification(task.id, task.title, newDueDate);
        } catch (e) {
          print("Error al reprogramar notificación al editar: $e");
        }
      }

      await _saveTasks(); // Guardar cambios async
    });
  }

  // 🔄 CORRECCIÓN CRÍTICA: Esta función elimina la tarea y realiza las operaciones
  // asíncronas en un microtask para no bloquear el hilo principal.
  /// Lógica para eliminar una tarea y guardar.
  Future<void> _deleteTask(Task task) async {
    // Actualizar la lista rápidamente en UI
    setState(() {
      _tasks.removeWhere((t) => t.id == task.id);
    });

    // Operaciones async que no deben bloquear UI
    Future.microtask(() async {
      try {
        await flutterLocalNotificationsPlugin.cancel(task.id);
      } catch (e) {
        print("Error al cancelar notificación al eliminar: $e");
      }

      await _saveTasks(); // Guardar cambios async
    });
  }

  /// Lógica para cambiar el estado de una tarea y guardar.
  void _changeTaskStatus(Task task, TaskStatus newStatus) {
    // Actualizar UI rápidamente
    setState(() {
      task.status = newStatus;
    });

    // Ejecutar operaciones pesadas (cancelar/schedule/save) fuera del setState
    Future.microtask(() async {
      if (newStatus == TaskStatus.terminada) {
        try {
          await flutterLocalNotificationsPlugin.cancel(task.id);
        } catch (e) {
          print("Error al cancelar notificación al terminar: $e");
        }
      }
      // Si se vuelve a marcar como PENDIENTE o EN PROCESO y tiene fecha, la reprogramamos.
      else if (task.dueDate != null) {
        try {
          await scheduleNotification(task.id, task.title, task.dueDate!);
        } catch (e) {
          print("Error al programar notificación al cambiar estado: $e");
        }
      }

      await _saveTasks(); // Guardar cambios async
    });
  }

  /// Construye el color de fondo para la tarjeta de la tarea según su estado.
  Color _getStatusColor(TaskStatus status) {
    switch (status) {
      // Ajuste de colores para que sean legibles sobre un fondo potencialmente oscuro.
      case TaskStatus.pendiente:
        return Colors.red.shade100;
      case TaskStatus.enProceso:
        return Colors.orange.shade100;
      case TaskStatus.terminada:
        return Colors.green.shade100;
      default:
        return Colors.grey.shade200;
    }
  }

  /// Construye el widget para mostrar el estado.
  Widget _buildStatusChip(Task task) {
    final Map<TaskStatus, Map<String, dynamic>> statusData = {
      TaskStatus.pendiente: {
        'label': 'PENDIENTE',
        'color': Colors.red.shade700,
        'icon': Icons.pending_actions
      },
      TaskStatus.enProceso: {
        'label': 'EN PROCESO',
        'color': Colors.orange.shade700,
        'icon': Icons.cached
      },
      TaskStatus.terminada: {
        'label': 'TERMINADA',
        'color': Colors.green.shade700,
        'icon': Icons.check_circle
      },
    };

    final data = statusData[task.status]!;

    return Chip(
      label: Text(data['label'],
          style: TextStyle(color: Colors.white, fontSize: 10)),
      avatar: Icon(data['icon'], color: Colors.white, size: 16),
      backgroundColor: data['color'],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    // -------------------------------------------------------------------------
    // ⚙️ LÓGICA DE ORDENAMIENTO POR PRIORIDAD Y FECHA
    // -------------------------------------------------------------------------
    _tasks.sort((a, b) {
      // 1. Poner tareas TERMINADAS al final.
      if (a.status == TaskStatus.terminada && b.status != TaskStatus.terminada) {
        return 1;
      }
      if (a.status != TaskStatus.terminada && b.status == TaskStatus.terminada) {
        return -1;
      }

      // 2. Si ambas NO están terminadas, ordenar por fecha de entrega más próxima.
      if (a.status != TaskStatus.terminada && b.status != TaskStatus.terminada) {
        // Poner tareas SIN FECHA DE ENTREGA al final de las no terminadas.
        if (a.dueDate == null && b.dueDate == null) return 0;
        if (a.dueDate == null) return 1;
        if (b.dueDate == null) return -1;

        // La fecha más antigua (más cercana a hoy) va primero.
        return a.dueDate!.compareTo(b.dueDate!);
      }

      // 3. Mantener el orden relativo si ambas están terminadas.
      return 0;
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Umbral: Tu Gestor de Tareas'),
      ),
      body: _tasks.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Icono visual de tarea
                  Icon(Icons.assignment_turned_in,
                      size: 80, color: Colors.grey.shade400), // Ajuste de color
                  const SizedBox(height: 16),
                  Text('¡Tu Umbral está vacío!',
                      style: TextStyle(
                          fontSize: 20,
                          color: Colors.grey.shade600)), // Ajuste de color
                  Text('Toca el "+" para empezar a organizar tu trabajo.',
                      style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey.shade500)), // Ajuste de color
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _tasks.length,
              itemBuilder: (context, index) {
                final task = _tasks[index];
                return Dismissible(
                  key: Key(task.id.toString()),
                  direction: DismissDirection.endToStart,
                  // ⚠️ Esta función pide confirmación antes de eliminar
                  confirmDismiss: (direction) async {
                    return await showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: const Text("Confirmar Eliminacion"),
                          content: Text(
                              "¿Estás seguro de que quieres eliminar la tarea: ${task.title}?"),
                          actions: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text("Cancelar"),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text("Eliminar",
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        );
                      },
                    );
                  },
                  onDismissed: (direction) {
                    // 🚨 FIX: Usamos Future.microtask para que la llamada a _deleteTask
                    // ocurra después de que el widget Dismissible termine su animación
                    // de descarte, evitando el "freeze".
                    Future.microtask(() async {
                      await _deleteTask(task);
                    });

                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content:
                            Text('${task.title} eliminada permanentemente.')));
                  },
                  // 🎨 Estilo del fondo al deslizar
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child:
                        const Icon(Icons.delete, color: Colors.white, size: 30),
                  ),
                  child: Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    color: _getStatusColor(task.status),
                    child: ListTile(
                      title: Text(
                        task.title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          decoration: task.status == TaskStatus.terminada
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                          color: task.status == TaskStatus.terminada
                              ? Colors.grey.shade600
                              : Colors.black,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          task.dueDate != null
                              ? Text(
                                  'Entrega: ${task.dueDate!.day}/${task.dueDate!.month}/${task.dueDate!.year}',
                                  style: TextStyle(
                                      color: task.dueDate!.isBefore(
                                                  DateTime.now().subtract(
                                                      const Duration(days: 1))) &&
                                              task.status != TaskStatus.terminada
                                          ? Colors.red.shade900
                                          : Colors.black54,
                                      fontWeight: FontWeight.w500),
                                )
                              : const Text('Sin fecha límite',
                                  style:
                                      TextStyle(fontStyle: FontStyle.italic)),
                          const SizedBox(height: 4),
                          _buildStatusChip(task),
                        ],
                      ),
                      trailing: PopupMenuButton<TaskStatus>(
                        onSelected: (TaskStatus result) {
                          _changeTaskStatus(task, result);
                        },
                        itemBuilder: (BuildContext context) =>
                            <PopupMenuEntry<TaskStatus>>[
                          const PopupMenuItem<TaskStatus>(
                            value: TaskStatus.pendiente,
                            child: ListTile(
                                leading: Icon(Icons.pending_actions,
                                    color: Colors.red),
                                title: Text('⏳ Pendiente')),
                          ),
                          const PopupMenuItem<TaskStatus>(
                            value: TaskStatus.enProceso,
                            child: ListTile(
                                leading:
                                    Icon(Icons.cached, color: Colors.orange),
                                title: Text('🔄 En Proceso')),
                          ),
                          const PopupMenuItem<TaskStatus>(
                            value: TaskStatus.terminada,
                            child: ListTile(
                                leading: Icon(Icons.check_circle,
                                    color: Colors.green),
                                title: Text('✅ Terminada')),
                          ),
                        ],
                        icon: const Icon(Icons.more_vert),
                      ),
                      onTap: () => _openTaskDialog(taskToEdit: task),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openTaskDialog(),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
        tooltip: 'Agregar Tarea',
        child: const Icon(Icons.add),
      ),
    );
  }
}