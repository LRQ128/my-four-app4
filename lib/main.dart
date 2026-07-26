import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import 'models/schedule.dart';
import 'models/solver.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SchedulingApp());
}

class SchedulingApp extends StatelessWidget {
  const SchedulingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '排班App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ============ 数据服务 ============

class DatabaseService {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/schedule.db';
    return await openDatabase(path, version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE schedules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            week_start TEXT NOT NULL,
            names TEXT NOT NULL,
            closing_day INTEGER NOT NULL,
            rest_days TEXT NOT NULL,
            days_json TEXT NOT NULL,
            locked INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE schedules ADD COLUMN locked INTEGER NOT NULL DEFAULT 0');
        }
      },
    );
  }

  static Future<void> saveSchedule(WeekSchedule schedule) async {
    final db = await database;
    final existing = await db.query('schedules',
        where: 'week_start = ?',
        whereArgs: [schedule.weekStart.toIso8601String()]);
    if (existing.isNotEmpty) {
      await db.update('schedules', {
        'names': schedule.names.join(','),
        'closing_day': schedule.closingDay,
        'rest_days': schedule.restDays.join(','),
        'days_json': DayScheduleEncoder.encodeList(schedule.days),
      }, where: 'week_start = ?',
          whereArgs: [schedule.weekStart.toIso8601String()]);
    } else {
      await db.insert('schedules', {
        'week_start': schedule.weekStart.toIso8601String(),
        'names': schedule.names.join(','),
        'closing_day': schedule.closingDay,
        'rest_days': schedule.restDays.join(','),
        'days_json': DayScheduleEncoder.encodeList(schedule.days),
        'locked': 0,
        'created_at': DateTime.now().toIso8601String(),
      });
    }
  }

  static Future<void> toggleLock(DateTime weekStart, bool locked) async {
    final db = await database;
    await db.update('schedules', {'locked': locked ? 1 : 0},
        where: 'week_start = ?',
        whereArgs: [weekStart.toIso8601String()]);
  }

  static Future<bool> isLocked(DateTime weekStart) async {
    final db = await database;
    final maps = await db.query('schedules',
        columns: ['locked'],
        where: 'week_start = ?',
        whereArgs: [weekStart.toIso8601String()]);
    if (maps.isEmpty) return false;
    return (maps.first['locked'] as int) == 1;
  }

  static Future<List<WeekSchedule>> loadSchedules() async {
    final db = await database;
    final maps = await db.query('schedules', orderBy: 'week_start DESC');
    return maps.map((m) {
      try {
        return WeekSchedule(
          weekStart: DateTime.parse(m['week_start'] as String),
          names: (m['names'] as String).split(','),
          closingDay: m['closing_day'] as int,
          restDays: (m['rest_days'] as String).split(',').map(int.parse).toList(),
          days: DayScheduleEncoder.decodeList(m['days_json'] as String),
          locked: (m['locked'] as int?) ?? 0,
        );
      } catch (_) {
        // 兼容旧数据格式
        return WeekSchedule(
          weekStart: DateTime.parse(m['week_start'] as String),
          names: (m['names'] as String).split(','),
          closingDay: m['closing_day'] as int,
          restDays: (m['rest_days'] as String).split(',').map(int.parse).toList(),
          days: DayScheduleEncoder.decodeList(m['days_json'] as String),
        );
      }
    }).toList();
  }

  static Future<List<WeekSchedule>> loadLockedSchedules() async {
    final db = await database;
    final maps = await db.query('schedules',
        where: 'locked = 1', orderBy: 'week_start DESC');
    return maps.map((m) => WeekSchedule(
      weekStart: DateTime.parse(m['week_start'] as String),
      names: (m['names'] as String).split(','),
      closingDay: m['closing_day'] as int,
      restDays: (m['rest_days'] as String).split(',').map(int.parse).toList(),
      days: DayScheduleEncoder.decodeList(m['days_json'] as String),
      locked: 1,
    )).toList();
  }

  static Future<void> saveSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String?> loadSetting(String key) async {
    final db = await database;
    final maps = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (maps.isEmpty) return null;
    return maps.first['value'] as String;
  }
}

// ============ 数据编解码 ============

class DayScheduleEncoder {
  static String encodeList(List<DaySchedule> days) {
    return days.map((d) => '${d.dayIndex}|${d.person99999}|${d.personXieguan}|${d.personRest}').join(';;');
  }

  static List<DaySchedule> decodeList(String data) {
    return data.split(';;').map((s) {
      final parts = s.split('|');
      return DaySchedule(
        dayIndex: int.parse(parts[0]),
        person99999: parts[1],
        personXieguan: parts[2],
        personRest: parts[3],
      );
    }).toList();
  }
}

// ============ 主页面 ============

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey _scheduleKey = GlobalKey();
  int _currentIndex = 0;
  List<String> _names = ['张三', '李四', '王五'];
  int _closingDay = 6; // 默认周六
  // 每人1天指定休班日(0=周日...6=周六)，系统自动补另外1天
  List<int> _restDays = [0, 2, 4];
  WeekSchedule? _currentSchedule;
  int _refreshOffset = 0;
  int _fullSolveOffset = 0; // 完整求解的偏移（切换不同休班分配）
  int _totalFullSolutions = 0; // 全部完整解数量
  int _weekOffset = 0; // 0=本周, 1=下周, 2=下下周
  List<int>? _fixedRestPeoplePerDay; // 固定后的每日休班人索引
  bool _hasInitialSolve = false; // 是否已首次求解
  List<WeekSchedule> _history = [];
  List<WeekSchedule> _lockedHistory = [];
  bool _isCurrentLocked = false;
  WeekSchedule? _viewingHistorySchedule; // 当前查看的历史排班
  int? _selectedHistoryIndex; // 展开的历史条目索引
  Map<int, Map<String, String>> _lastRefreshInputs = {}; // 上次刷新填写的记忆

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadHistory();
  }

  Future<void> _loadSettings() async {
    final namesStr = await DatabaseService.loadSetting('names');
    if (namesStr != null) {
      setState(() => _names = namesStr.split(','));
    }
    final closingStr = await DatabaseService.loadSetting('closing_day');
    if (closingStr != null) {
      setState(() => _closingDay = int.parse(closingStr));
    }
    final restStr = await DatabaseService.loadSetting('rest_days');
    if (restStr != null) {
      final parts = restStr.split(',').map(int.parse).toList();
      if (parts.length == 3) {
        setState(() => _restDays = parts);
      }
    }
  }

  Future<void> _loadHistory() async {
    final schedules = await DatabaseService.loadSchedules();
    final locked = await DatabaseService.loadLockedSchedules();
    setState(() {
      _history = schedules;
      _lockedHistory = locked;
    });
  }

  /// 根据周偏移获取周一日期
  DateTime _getMonday(int offset) {
    final now = DateTime.now();
    final daysSinceMonday = now.weekday - 1;
    return now.subtract(Duration(days: daysSinceMonday))
        .add(Duration(days: offset * 7));
  }

  /// 获取前一周排班的周日(dayIndex=6)盯99999的人
  /// _history 按 week_start DESC 排序（最新在前），
  /// 所以如果有2周以上记录则取 _history[1] 才是真正的上一周
  String? _getLastSunday99999() {
    if (_history.isEmpty) return null;
    final WeekSchedule previousWeek;
    if (_history.length >= 2) {
      previousWeek = _history[1];
    } else {
      previousWeek = _history.first;
    }
    for (final day in previousWeek.days) {
      if (day.dayIndex == 6) return day.person99999;
    }
    return null;
  }

  /// 加载当前排班的固定状态
  Future<void> _loadLockedState(DateTime weekStart) async {
    final locked = await DatabaseService.isLocked(weekStart);
    if (mounted) setState(() => _isCurrentLocked = locked);
  }

  /// 固定/取消固定当前排班
  Future<void> _toggleLockCurrent() async {
    if (_currentSchedule == null) return;
    final newLocked = !_isCurrentLocked;
    await DatabaseService.toggleLock(
        _currentSchedule!.weekStart, newLocked);
    _currentSchedule!.locked = newLocked ? 1 : 0;
    if (mounted) {
      setState(() => _isCurrentLocked = newLocked);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(newLocked ? '✅ 已固定该周排班' : '已取消固定'),
          backgroundColor: newLocked ? Colors.green : Colors.grey,
        ),
      );
    }
    await _loadHistory();
  }

  /// 首次完全求解：所有休班日已由用户指定，只分配99999/协管
  /// [lastSunday99999] 可手动指定上周日盯99999的人（用于跨周连续性约束）
  Future<void> _generateSchedule({String? lastSunday99999}) async {
    final solver = SimpleScheduleSolver(
      names: _names,
      userRestDays: _restDays.map(_toSolverDay).toList(),
      closingDay: _toSolverDay(_closingDay),
      lastSunday99999: lastSunday99999 ?? _getLastSunday99999(),
    );

    final monday = _getMonday(_weekOffset);
    final result = solver.solveWithCount(monday, offset: _fullSolveOffset);
    final schedule = result.key;
    final totalCount = result.value;
    _totalFullSolutions = totalCount;

    if (schedule != null) {
      final workingDays = schedule.days.map((d) => d.dayIndex).toList()..sort();
      final restIndices = workingDays.map((di) {
        final day = schedule.days.firstWhere((d) => d.dayIndex == di);
        return _names.indexOf(day.personRest);
      }).toList();
      
      await DatabaseService.saveSetting('rest_days', _restDays.join(','));
      await DatabaseService.saveSchedule(schedule);
      setState(() {
        _currentSchedule = schedule;
        _fixedRestPeoplePerDay = restIndices;
        _hasInitialSolve = true;
        _refreshOffset = 0;
      });
      await _loadHistory();
      await _loadLockedState(schedule.weekStart);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_weekLabel(_weekOffset)}排班成功！'), backgroundColor: Colors.green),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法生成排班，请检查约束条件'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// 加载已有排班（优先从历史记录加载，没有则重新生成）
  Future<void> _loadScheduleForWeek() async {
    final monday = _getMonday(_weekOffset);

    // 查锁定记录
    for (final s in _lockedHistory) {
      if (s.weekStart.year == monday.year &&
          s.weekStart.month == monday.month &&
          s.weekStart.day == monday.day) {
        setState(() {
          _currentSchedule = s;
          _isCurrentLocked = true;
        });
        return;
      }
    }

    // 查普通历史记录
    for (final s in _history) {
      if (s.weekStart.year == monday.year &&
          s.weekStart.month == monday.month &&
          s.weekStart.day == monday.day) {
        setState(() {
          _currentSchedule = s;
          _isCurrentLocked = false;
        });
        return;
      }
    }

    // 没有历史记录，重新生成
    await _generateSchedule();
  }

  /// 弹出角色指定输入框
  Future<void> _showRefreshDialog() async {
    if (_currentSchedule == null) return;

    final schedule = _currentSchedule!;
    final weekDays = schedule.days.map((d) => d.dayIndex).toList()..sort();

    // 创建每个日期每项的控制器（默认空，有记忆则填上记忆的值）
    final controllers = <int, Map<String, TextEditingController>>{};
    for (final dayIndex in weekDays) {
      final saved = _lastRefreshInputs[dayIndex];
      controllers[dayIndex] = {
        '99999': TextEditingController(text: saved?['99999'] ?? ''),
        '协管': TextEditingController(text: saved?['协管'] ?? ''),
      };
    }

    final result = await showDialog<Map<int, Map<String, String?>>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.edit_note, size: 22),
                  SizedBox(width: 8),
                  Text('手动指定角色'),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '填写你想指定的人员到对应格子里，留空则由系统自动分配',
                        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 12),
                      // 表头
                      Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 6),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(
                                width: 54,
                                child: Text('日期',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold))),
                            const Expanded(
                                child: Text('🏦 99999',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold))),
                            const Expanded(
                                child: Text('🤝 协管',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold))),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...weekDays.map((dayIndex) {
                        final day = schedule.days
                            .firstWhere((d) => d.dayIndex == dayIndex);
                        final dayDate =
                            schedule.weekStart.add(Duration(days: dayIndex));
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 54,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Text(_dayName(dayIndex),
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13)),
                                    Text('${dayDate.month}/${dayDate.day}',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey[500])),
                                    if (_isUserSpecifiedRestDay(
                                        dayIndex, day.personRest))
                                      Container(
                                        margin:
                                            const EdgeInsets.only(top: 2),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.orange[100],
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text('休${day.personRest}',
                                            style: TextStyle(
                                                fontSize: 9,
                                                color: Colors.orange[800])),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: SizedBox(
                                  height: 42,
                                  child: TextField(
                                    controller:
                                        controllers[dayIndex]!['99999'],
                                    decoration: const InputDecoration(
                                      hintText: '谁盯99999',
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 8),
                                      isDense: true,
                                    ),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: SizedBox(
                                  height: 42,
                                  child: TextField(
                                    controller:
                                        controllers[dayIndex]!['协管'],
                                    decoration: const InputDecoration(
                                      hintText: '谁协管',
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 8),
                                      isDense: true,
                                    ),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    final constraints =
                        <int, Map<String, String?>>{};
                    for (final dayIndex in weekDays) {
                      final v99999 = controllers[dayIndex]!['99999']!
                          .text
                          .trim();
                      final vXieguan = controllers[dayIndex]!['协管']!
                          .text
                          .trim();

                      for (final entry in [{'role': '99999', 'name': v99999},
                          {'role': '协管', 'name': vXieguan}]) {
                        if (entry['name']!.isNotEmpty &&
                            !_names.contains(entry['name'])) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(
                                  '"${entry['name']}" 不是当前柜员！'),
                              backgroundColor: Colors.red,
                            ),
                          );
                          return;
                        }
                      }

                      final constraint = <String, String?>{};
                      if (v99999.isNotEmpty) constraint['99999'] = v99999;
                      if (vXieguan.isNotEmpty) constraint['协管'] = vXieguan;
                      if (constraint.isNotEmpty) {
                        constraints[dayIndex] = constraint;
                      }
                    }
                    // 保存本次填写到记忆
                    _lastRefreshInputs = {};
                    for (final dayIndex in weekDays) {
                      final v99999 = controllers[dayIndex]!['99999']!
                          .text
                          .trim();
                      final vXieguan = controllers[dayIndex]!['协管']!
                          .text
                          .trim();
                      final saved = <String, String>{};
                      if (v99999.isNotEmpty) saved['99999'] = v99999;
                      if (vXieguan.isNotEmpty) saved['协管'] = vXieguan;
                      if (saved.isNotEmpty) {
                        _lastRefreshInputs[dayIndex] = saved;
                      }
                    }
                    Navigator.pop(ctx, constraints);
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('确定刷新'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null) {
      await _applyConstraints(result);
    }
  }

  /// 按用户填写的约束重新求解角色分配
  Future<void> _applyConstraints(
      Map<int, Map<String, String?>> constraints) async {
    if (_currentSchedule == null || _fixedRestPeoplePerDay == null) return;

    final schedule = _currentSchedule!;
    final weekDays = schedule.days.map((d) => d.dayIndex).toList()..sort();

    final solver = SimpleScheduleSolver(
      names: _names,
      userRestDays: _restDays.map(_toSolverDay).toList(),
      closingDay: _toSolverDay(_closingDay),
      lastSunday99999: _getLastSunday99999(),
    );

    final newSchedule = solver.solveWithFixedRestAndConstraints(
      schedule.weekStart,
      _fixedRestPeoplePerDay!,
      weekDays,
      constraints,
    );

    if (newSchedule != null) {
      await DatabaseService.saveSchedule(newSchedule);
      setState(() => _currentSchedule = newSchedule);
      await _loadHistory();
      await _loadLockedState(newSchedule.weekStart);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 组合已切换'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ 无该种组合'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// 构建导出专用完整排班表（非滚动式，所有天在一行）
  Future<void> _exportToImage() async {
    if (_currentSchedule == null) return;

    final schedule = _currentSchedule!;

    // 用 Builder 包裹确保 context 可用，直接截图后关闭弹窗
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ExportDialog(
        schedule: schedule,
        weekLabel: _weekLabel(_weekOffset),
        dayName: _dayName,
        getDateRange: getDateRange,
        onDone: (success, message) {
          if (ctx.mounted) Navigator.pop(ctx);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                backgroundColor: success ? Colors.green : Colors.red,
              ),
            );
          }
        },
      ),
    );
  }

  String getDateRange(WeekSchedule s) {
    final sorted = s.days.map((d) => d.dayIndex).toList()..sort();
    if (sorted.isEmpty) return '';
    final first = s.weekStart.add(Duration(days: sorted.first));
    final last = s.weekStart.add(Duration(days: sorted.last));
    return '${first.month}/${first.day} - ${last.month}/${last.day}';
  }

  String _dayName(int dayIndex) {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[dayIndex];
  }

  /// 天数映射：设置(0=周日,1=周一...6=周六) → 算法(0=周一...6=周日)
  int _toSolverDay(int d) => (d + 6) % 7;

  /// 判断某天某人的休班是否是用户指定的
  bool _isUserSpecifiedRestDay(int solverDayIndex, String personName) {
    final personIdx = _names.indexOf(personName);
    if (personIdx < 0 || personIdx >= _restDays.length) return false;
    final solverRestDay = _toSolverDay(_restDays[personIdx]);
    return solverDayIndex == solverRestDay;
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    String title;
    switch (_currentIndex) {
      case 0:
        title = '排班App';
        body = _currentSchedule == null ? _buildEmptyState() : _buildScheduleView();
        break;
      case 1:
        title = '设置';
        body = _buildSettingsView();
        break;
      case 2:
        title = '历史记录';
        body = _buildHistoryView();
        break;
      default:
        title = '排班App';
        body = _currentSchedule == null ? _buildEmptyState() : _buildScheduleView();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_currentIndex == 0 && _currentSchedule != null) ...[            
            IconButton(
              icon: Icon(
                  _isCurrentLocked ? Icons.lock : Icons.lock_open,
                  color: _isCurrentLocked ? Colors.green : null),
              onPressed: _toggleLockCurrent,
              tooltip: _isCurrentLocked ? '取消固定' : '固定该周',
            ),
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: _exportToImage,
              tooltip: '导出排班表',
            ),
          ],
        ],
      ),
      body: body,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: '排班'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: '历史'),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.calendar_today, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('暂无排班', style: TextStyle(fontSize: 18, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text('请先在设置中配置柜员和休班日', style: TextStyle(color: Colors.grey[500])),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _showSettings,
            icon: const Icon(Icons.settings),
            label: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleView() {
    final schedule = _currentSchedule!;
    // 从排班数据直接取天数，排除关门日
        final weekDays = schedule.days.map((d) => d.dayIndex).toList()..sort();

    return RepaintBoundary(
      key: _scheduleKey,
      child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // 周次选择
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _weekLabel(_weekOffset),
                          items: const [
                            DropdownMenuItem(value: '本周', child: Text('本周', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20))),
                            DropdownMenuItem(value: '下周', child: Text('下周', style: TextStyle(fontSize: 20))),
                            DropdownMenuItem(value: '下下周', child: Text('下下周', style: TextStyle(fontSize: 20))),
                          ],
                          onChanged: (v) {
                            int newOffset = v == '本周' ? 0 : (v == '下周' ? 1 : 2);
                            setState(() => _weekOffset = newOffset);
                            _loadScheduleForWeek();
                          },
                        ),
                      ),
                      const Spacer(),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: _showRefreshDialog,
                            icon: const Icon(Icons.refresh, size: 20),
                            tooltip: '手动指定角色',
                          ),
                          TextButton.icon(
                            onPressed: _showNextWeekRestDialog,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('生成下周'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 4),
                    child: Text(getDateRange(schedule), style: TextStyle(color: Colors.grey[600])),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 水平滚动日历式排班表
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: weekDays.length,
              itemBuilder: (context, index) {
                final dayIndex = weekDays[index];
                final day = schedule.days.firstWhere((d) => d.dayIndex == dayIndex);
                final dayDate = schedule.weekStart.add(Duration(days: dayIndex));
                final today = DateTime.now();
                final isToday = dayDate.year == today.year &&
                                dayDate.month == today.month &&
                                dayDate.day == today.day;

                return Container(
                  width: 130,
                  margin: const EdgeInsets.only(right: 8),
                  child: Card(
                    color: isToday ? Colors.blue[50] : null,
                    shape: isToday
                        ? RoundedRectangleBorder(
                            side: BorderSide(color: Colors.blue, width: 2),
                            borderRadius: BorderRadius.circular(12),
                          )
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 日期头
                          Text(
                            _dayName(dayIndex),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: isToday ? Colors.blue : null,
                            ),
                          ),
                          Text(
                            '${dayDate.month}/${dayDate.day}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                          if (isToday)
                            Container(
                              margin: const EdgeInsets.only(top: 2),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.blue,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text('今天', style: TextStyle(color: Colors.white, fontSize: 10)),
                            ),
                          const Divider(height: 12),

                          // 人员分配
                          _buildSlot('🏦 99999', day.person99999),
                          const SizedBox(height: 3),
                          _buildSlot('🤝 协管', day.personXieguan),
                          const SizedBox(height: 3),

                          // 休班（仅用户指定休班日才显示）
                          if (_isUserSpecifiedRestDay(dayIndex, day.personRest))
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.orange[100],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text('休班 ${day.personRest}',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),

                          // 中午休息（上班但午休）
                          if (day.personNoonRest.isNotEmpty)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.free_breakfast, size: 12, color: Colors.brown[400]),
                                const SizedBox(width: 2),
                                Text('午休 ${day.personNoonRest}',
                                    style: TextStyle(fontSize: 11, color: Colors.brown[600])),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 16),

          // 统计
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本周统计', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  ...schedule.names.map((name) {
                    int count99999 = 0, countXieguan = 0;
                    for (final day in schedule.days) {
                      if (day.person99999 == name) count99999++;
                      if (day.personXieguan == name) countXieguan++;
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        children: [
                          SizedBox(width: 64, child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold))),
                          Text('🏦×$count99999  🤝×$countXieguan'),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildSlot(String label, String name) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('$label ', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        Text(name, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
      ],
    );
  }


  String _weekLabel(int offset) {
    switch (offset) {
      case 0: return '本周';
      case 1: return '下周';
      case 2: return '下下周';
      default: return '第${offset + 1}周';
    }
  }

  /// 弹出休班日调整对话框
  Future<void> _showNextWeekRestDialog() async {
    if (_currentSchedule == null) return;
    
    // 默认下周继续使用当前休班日设置
    List<int> newRestDays = List.from(_restDays);
    
    final result = await showDialog<List<int>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('下周休班日调整'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('为下周每位柜员选择1天休班日（系统自动补另1天）：',
                        style: TextStyle(fontSize: 14)),
                    const SizedBox(height: 16),
                    ...List.generate(_names.length, (i) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: DropdownButtonFormField<int>(
                          value: newRestDays[i],
                          decoration: InputDecoration(
                            labelText: '${_names[i]} 休班日',
                            border: const OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('周日')),
                            DropdownMenuItem(value: 1, child: Text('周一')),
                            DropdownMenuItem(value: 2, child: Text('周二')),
                            DropdownMenuItem(value: 3, child: Text('周三')),
                            DropdownMenuItem(value: 4, child: Text('周四')),
                            DropdownMenuItem(value: 5, child: Text('周五')),
                          ],
                          onChanged: (v) {
                            setDialogState(() => newRestDays[i] = v!);
                          },
                        ),
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, newRestDays),
                  child: const Text('确认生成'),
                ),
              ],
            );
          },
        );
      },
    );
    
    if (result != null) {
      // 用户确认后，用调整后的休班日生成下周
      await _doGenerateNextWeek(result);
    }
  }

  /// 实际生成下周排班
  Future<void> _doGenerateNextWeek(List<int> nextWeekRestDays) async {
    if (_currentSchedule == null) return;
    final nextMonday = _currentSchedule!.weekStart.add(const Duration(days: 7));
    
    // 获取当前周周日(dayIndex=6)盯99999的人作为跨周约束
    String? lastSunday99999;
    for (final day in _currentSchedule!.days) {
      if (day.dayIndex == 6) {
        lastSunday99999 = day.person99999;
        break;
      }
    }

    final solver = SimpleScheduleSolver(
      names: _names,
      userRestDays: nextWeekRestDays.map(_toSolverDay).toList(),
      closingDay: _toSolverDay(_closingDay),
      lastSunday99999: lastSunday99999,
    );

    final result = solver.solveWithCount(nextMonday, offset: _fullSolveOffset);
    final schedule = result.key;
    final totalCount = result.value;
    _totalFullSolutions = totalCount;
    if (schedule != null) {
      // 固定下周的休班日
      final workingDays = schedule.days.map((d) => d.dayIndex).toList()..sort();
      final restIndices = workingDays.map((di) {
        final day = schedule.days.firstWhere((d) => d.dayIndex == di);
        return _names.indexOf(day.personRest);
      }).toList();
      
      await DatabaseService.saveSetting('rest_days', nextWeekRestDays.join(','));
      await DatabaseService.saveSchedule(schedule);
      setState(() {
        _restDays = nextWeekRestDays;
        _currentSchedule = schedule;
        _fixedRestPeoplePerDay = restIndices;
        _hasInitialSolve = true;
        _refreshOffset = 0;
        _weekOffset = 1; // 切换到下周
      });
      await _loadHistory();
      await _loadLockedState(schedule.weekStart);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下周排班已生成！'), backgroundColor: Colors.green),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('排班失败，请检查设置'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// 弹出连续性确认对话框
  /// 生成非本周排班时，询问是否与上一周相连
  /// 返回：null=取消, Map中 lastSunday99999=null=不连续, 否则为指定柜员名
  Future<Map<String, dynamic>?> _promptContinuityIfNeeded(int weekOffset) async {
    if (weekOffset <= 0) {
      return {'lastSunday99999': null}; // 本周无需连续性
    }

    // 检查上一周的排班是否已锁定
    final prevMonday = _getMonday(weekOffset - 1);
    for (final s in _lockedHistory) {
      if (s.weekStart.year == prevMonday.year &&
          s.weekStart.month == prevMonday.month &&
          s.weekStart.day == prevMonday.day) {
        String? prevSunday99999;
        for (final d in s.days) {
          if (d.dayIndex == 6) prevSunday99999 = d.person99999;
        }
        return {'lastSunday99999': prevSunday99999};
      }
    }
    // 上一周未锁定，手动询问
    bool isContinuous = false;
    String? selectedPerson;

    return await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.link, size: 22),
                  SizedBox(width: 8),
                  Text('跨周连续性'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('是否与上一周相连？\n如果相连，上周日盯99999的人下周一时不能盯99999。'),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: const Text('与上一周相连'),
                    subtitle: Text(isContinuous ? '已开启连续性规则' : '不启用连续性规则'),
                    value: isContinuous,
                    onChanged: (v) => setDialogState(() {
                      isContinuous = v;
                      if (!v) selectedPerson = null;
                    }),
                  ),
                  if (isContinuous) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: selectedPerson,
                      decoration: const InputDecoration(
                        labelText: '上周日盯99999的柜员',
                        border: OutlineInputBorder(),
                      ),
                      items: _names
                          .map((n) => DropdownMenuItem(value: n, child: Text(n)))
                          .toList(),
                      onChanged: (v) => setDialogState(() => selectedPerson = v),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消生成'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (isContinuous && selectedPerson == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                            content: Text('请选择上周日盯99999的柜员'),
                            backgroundColor: Colors.orange),
                      );
                      return;
                    }
                    Navigator.pop(ctx, {
                      'lastSunday99999': isContinuous ? selectedPerson : null,
                    });
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 构建设置视图（嵌入排班Tab中）
  Widget _buildSettingsView() {
    return SettingsView(
      names: List.from(_names),
      closingDay: _closingDay,
      restDays: List.from(_restDays),
      weekOffset: _weekOffset,
      onSave: (names, closingDay, restDays, weekOffset) async {
        setState(() {
          _names = names;
          _closingDay = closingDay;
          _restDays = restDays;
          _weekOffset = weekOffset;
        });
        await DatabaseService.saveSetting('names', names.join(','));
        await DatabaseService.saveSetting('closing_day', closingDay.toString());
        await DatabaseService.saveSetting('rest_days', restDays.join(','));
        _currentIndex = 0;

        // 生成非本周排班时处理连续性
        final continuity = await _promptContinuityIfNeeded(weekOffset);
        if (continuity == null) {
          // 用户取消了生成
          return;
        }
        await _generateSchedule(
            lastSunday99999: continuity['lastSunday99999'] as String?);
      },
    );
  }

  /// 构建历史记录视图
  Widget _buildHistoryView() {
    if (_lockedHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('暂无固定排班记录',
                style: TextStyle(fontSize: 18, color: Colors.grey[600])),
            const SizedBox(height: 8),
            Text('生成排班后点击🔒按钮固定即可在此查看',
                style: TextStyle(color: Colors.grey[500])),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _lockedHistory.length,
      itemBuilder: (context, index) {
        final s = _lockedHistory[index];
        final isExpanded = _selectedHistoryIndex == index;
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _selectedHistoryIndex = null;
                  _viewingHistorySchedule = null;
                } else {
                  _selectedHistoryIndex = index;
                  _viewingHistorySchedule = s;
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lock, size: 16, color: Colors.green),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          getDateRange(s),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: Colors.grey,
                      ),
                    ],
                  ),
                  if (isExpanded) ...[                    
                    const Divider(),
                    ...s.names.map((name) {
                      int c9 = 0, cx = 0;
                      for (final d in s.days) {
                        if (d.person99999 == name) c9++;
                        if (d.personXieguan == name) cx++;
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            SizedBox(
                                width: 64,
                                child: Text(name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold))),
                            Text('99999×$c9  协管×$cx'),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _currentSchedule = WeekSchedule(
                              weekStart: s.weekStart,
                              names: List.from(s.names),
                              closingDay: s.closingDay,
                              restDays: List.from(s.restDays),
                              days: s.days
                                  .map((d) => DaySchedule(
                                        dayIndex: d.dayIndex,
                                        person99999: d.person99999,
                                        personXieguan: d.personXieguan,
                                        personRest: d.personRest,
                                      ))
                                  .toList(),
                              locked: s.locked,
                            );
                            _isCurrentLocked = true;
                            _currentIndex = 0;
                            _selectedHistoryIndex = null;
                            _viewingHistorySchedule = null;
                          });
                        },
                        icon: const Icon(Icons.visibility, size: 18),
                        label: const Text('查看此周排班'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSettings() {
    _currentIndex = 1;
    setState(() {});
  }
}

// ============ 导出对话框（独立 Widget 保证截图可靠） ============

class _ExportDialog extends StatefulWidget {
  final WeekSchedule schedule;
  final String weekLabel;
  final String Function(int) dayName;
  final String Function(WeekSchedule) getDateRange;
  final void Function(bool success, String message) onDone;

  const _ExportDialog({
    required this.schedule,
    required this.weekLabel,
    required this.dayName,
    required this.getDateRange,
    required this.onDone,
  });

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog>
    with SingleTickerProviderStateMixin {
  final _exportKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 延迟两帧确保布局完成后再截图
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 200), _capture);
    });
  }

  Future<void> _capture() async {
    try {
      final boundary = _exportKey.currentContext?.findRenderObject();
      if (boundary == null || boundary is! RenderRepaintBoundary) {
        widget.onDone(false, '导出失败：无法获取排班表区域');
        return;
      }
      final repaint = boundary as RenderRepaintBoundary;
      final image = await repaint.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        widget.onDone(false, '导出失败：图片数据为空');
        return;
      }
      final pngBytes = byteData.buffer.asUint8List();

      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/schedule_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(pngBytes);

      // 保存到手机相册
      try {
        const channel = MethodChannel('gallery_saver');
        await channel.invokeMethod('saveToGallery', {'filePath': file.path});
        widget.onDone(true, '✅ 排班表已保存到「相册-排班表」文件夹');
      } catch (_) {
        widget.onDone(true, '✅ 图片已保存到临时目录:\n${file.path}');
      }
    } catch (e) {
      widget.onDone(false, '导出失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final schedule = widget.schedule;
    final weekDays = schedule.days.map((d) => d.dayIndex).toList()..sort();

    return Dialog(
      insetPadding: const EdgeInsets.all(4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: RepaintBoundary(
          key: _exportKey,
          child: Container(
            width: weekDays.length * 155.0 + 32,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('排班表 - ${widget.weekLabel}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                Text(widget.getDateRange(schedule),
                    style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: weekDays.map((dayIndex) {
                    final day = schedule.days
                        .firstWhere((d) => d.dayIndex == dayIndex);
                    final dayDate =
                        schedule.weekStart.add(Duration(days: dayIndex));
                    final today = DateTime.now();
                    final isToday = dayDate.year == today.year &&
                        dayDate.month == today.month &&
                        dayDate.day == today.day;
                    return Container(
                      width: 140,
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isToday ? Colors.blue[50] : Colors.grey[50],
                        border: Border.all(
                            color:
                                isToday ? Colors.blue : Colors.grey[300]!),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Text(widget.dayName(dayIndex),
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: isToday ? Colors.blue : null)),
                          Text('${dayDate.month}/${dayDate.day}',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[500])),
                          if (isToday)
                            const Text('📅', style: TextStyle(fontSize: 12)),
                          const Divider(height: 8),
                          Text('99999 ${day.person99999}',
                              style: const TextStyle(fontSize: 12)),
                          Text('协管 ${day.personXieguan}',
                              style: const TextStyle(fontSize: 12)),
                          if (day.personRest.isNotEmpty &&
                              _isUserRestDay(schedule, dayIndex))
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange[100],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('休班 ${day.personRest}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange[800])),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                Text('统计',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold)),
                ...schedule.names.map((name) {
                  int c9 = 0, cx = 0;
                  for (final d in schedule.days) {
                    if (d.person99999 == name) c9++;
                    if (d.personXieguan == name) cx++;
                  }
                  return Text('$name: 99999×$c9  协管×$cx',
                      style: const TextStyle(fontSize: 12));
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isUserRestDay(WeekSchedule schedule, int dayIndex) {
    for (int i = 0; i < schedule.names.length; i++) {
      if (i < schedule.restDays.length &&
          schedule.restDays[i] == dayIndex) {
        return true;
      }
    }
    return false;
  }
}

// ============ 设置视图（嵌入Tab中） ============

class SettingsView extends StatefulWidget {
  final List<String> names;
  final int closingDay;
  final List<int> restDays;
  final int weekOffset;
  final Function(List<String>, int, List<int>, int) onSave;

  const SettingsView({
    super.key,
    required this.names,
    required this.closingDay,
    required this.restDays,
    required this.weekOffset,
    required this.onSave,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late List<TextEditingController> _nameControllers;
  late int _closingDay;
  late List<int> _restDays;
  late int _weekOffset;

  String _weekLabel(int offset) {
    switch (offset) {
      case 0: return '本周';
      case 1: return '下周';
      case 2: return '下下周';
      default: return '第${offset + 1}周';
    }
  }

  @override
  void initState() {
    super.initState();
    _nameControllers =
        widget.names.map((n) => TextEditingController(text: n)).toList();
    _closingDay = widget.closingDay;
    _restDays = List.from(widget.restDays);
    _weekOffset = widget.weekOffset;
  }

  @override
  void dispose() {
    for (var c in _nameControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 柜员姓名设置
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('柜员姓名',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                ...List.generate(3, (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _nameControllers[i],
                    decoration: InputDecoration(
                      labelText: '柜员${i + 1}',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                )),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 关门日设置
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('每周关门日',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  value: _closingDay,
                  decoration:
                      const InputDecoration(border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('周日')),
                    DropdownMenuItem(value: 1, child: Text('周一')),
                    DropdownMenuItem(value: 2, child: Text('周二')),
                    DropdownMenuItem(value: 3, child: Text('周三')),
                    DropdownMenuItem(value: 4, child: Text('周四')),
                    DropdownMenuItem(value: 5, child: Text('周五')),
                    DropdownMenuItem(value: 6, child: Text('周六')),
                  ],
                  onChanged: (v) => setState(() => _closingDay = v!),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 休班日设置（每人1天指定休班，系统自动补另1天）
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('每人1天指定休班日',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                ...List.generate(3, (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DropdownButtonFormField<int>(
                    value: _restDays[i],
                    decoration: InputDecoration(
                      labelText: '${_nameControllers[i].text} 休班日',
                      border: const OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('周日')),
                      DropdownMenuItem(value: 1, child: Text('周一')),
                      DropdownMenuItem(value: 2, child: Text('周二')),
                      DropdownMenuItem(value: 3, child: Text('周三')),
                      DropdownMenuItem(value: 4, child: Text('周四')),
                      DropdownMenuItem(value: 5, child: Text('周五')),
                    ],
                    onChanged: (v) => setState(() => _restDays[i] = v!),
                  ),
                )),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 选择生成哪周
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('生成排班计划',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  value: _weekOffset,
                  decoration:
                      const InputDecoration(border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('本周')),
                    DropdownMenuItem(value: 1, child: Text('下周')),
                    DropdownMenuItem(value: 2, child: Text('下下周')),
                  ],
                  onChanged: (v) => setState(() => _weekOffset = v!),
                ),
                const SizedBox(height: 8),
                Text(
                  '当前选择：${_weekLabel(_weekOffset)}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),

        // 生成排班按钮
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: () {
              widget.onSave(
                _nameControllers.map((c) => c.text).toList(),
                _closingDay,
                _restDays,
                _weekOffset,
              );
            },
            icon: const Icon(Icons.auto_awesome),
            label: const Text('保存并生成排班',
                style: TextStyle(fontSize: 16)),
          ),
        ),
      ],
    );
  }
}
