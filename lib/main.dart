import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

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
    return await openDatabase(path, version: 1, onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE schedules (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          week_start TEXT NOT NULL,
          names TEXT NOT NULL,
          closing_day INTEGER NOT NULL,
          rest_days TEXT NOT NULL,
          days_json TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    });
  }

  static Future<void> saveSchedule(WeekSchedule schedule) async {
    final db = await database;
    await db.insert('schedules', {
      'week_start': schedule.weekStart.toIso8601String(),
      'names': schedule.names.join(','),
      'closing_day': schedule.closingDay,
      'rest_days': schedule.restDays.join(','),
      'days_json': DayScheduleEncoder.encodeList(schedule.days),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<WeekSchedule>> loadSchedules() async {
    final db = await database;
    final maps = await db.query('schedules', orderBy: 'week_start DESC');
    return maps.map((m) => WeekSchedule(
      weekStart: DateTime.parse(m['week_start'] as String),
      names: (m['names'] as String).split(','),
      closingDay: m['closing_day'] as int,
      restDays: (m['rest_days'] as String).split(',').map(int.parse).toList(),
      days: DayScheduleEncoder.decodeList(m['days_json'] as String),
    )).toList();
  }

  static Future<WeekSchedule?> loadLatestSchedule() async {
    final db = await database;
    final maps = await db.query('schedules', orderBy: 'week_start DESC', limit: 1);
    if (maps.isEmpty) return null;
    final m = maps.first;
    return WeekSchedule(
      weekStart: DateTime.parse(m['week_start'] as String),
      names: (m['names'] as String).split(','),
      closingDay: m['closing_day'] as int,
      restDays: (m['rest_days'] as String).split(',').map(int.parse).toList(),
      days: DayScheduleEncoder.decodeList(m['days_json'] as String),
    );
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
  List<int> _restDays = [0,2, 4]; // 默认休班日
  WeekSchedule? _currentSchedule;
  int _refreshOffset = 0;
  int _weekOffset = 0; // 0=本周, 1=下周, 2=下下周
  List<int>? _fixedRestPeoplePerDay; // 固定后的每日休班人索引
  bool _hasInitialSolve = false; // 是否已首次求解
  List<WeekSchedule> _history = [];

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
  }

  Future<void> _loadHistory() async {
    final schedules = await DatabaseService.loadSchedules();
    setState(() => _history = schedules);
  }

  /// 根据周偏移获取周一日期
  DateTime _getMonday(int offset) {
    final now = DateTime.now();
    final daysSinceMonday = now.weekday - 1;
    return now.subtract(Duration(days: daysSinceMonday))
        .add(Duration(days: offset * 7));
  }

  /// 获取上周排班的周日(lastDayIndex=6)盯99999的人
  String? _getLastSunday99999() {
    if (_history.isEmpty) return null;
    final lastWeek = _history.first;
    for (final day in lastWeek.days) {
      if (day.dayIndex == 6) return day.person99999;
    }
    return null;
  }

  /// 首次完全求解：确定休班日+角色分配
  Future<void> _generateSchedule() async {
    final solver = SimpleScheduleSolver(
      names: _names,
      userRestDays: _restDays.map(_toSolverDay).toList(),
      closingDay: _toSolverDay(_closingDay),
      lastSunday99999: _getLastSunday99999(),
    );

    final monday = _getMonday(_weekOffset);
    final schedule = solver.solve(monday);

    if (schedule != null) {
      // 提取每日休班人索引，固定下来
      final workingDays = schedule.days.map((d) => d.dayIndex).toList()..sort();
      final restIndices = workingDays.map((di) {
        final day = schedule.days.firstWhere((d) => d.dayIndex == di);
        return _names.indexOf(day.personRest);
      }).toList();
      
      await DatabaseService.saveSchedule(schedule);
      setState(() {
        _currentSchedule = schedule;
        _fixedRestPeoplePerDay = restIndices;
        _hasInitialSolve = true;
        _refreshOffset = 0;
      });
      await _loadHistory();

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

  /// 刷新：仅重排 99999/协管，保持休班日不变
  Future<void> _refreshSchedule() async {
    if (_currentSchedule == null || _fixedRestPeoplePerDay == null) {
      // 还没首次求解过，回退到完全求解
      _refreshOffset++;
      await _generateSchedule();
      return;
    }

    _refreshOffset++;

    final solver = SimpleScheduleSolver(
      names: _names,
      userRestDays: _restDays.map(_toSolverDay).toList(),
      closingDay: _toSolverDay(_closingDay),
      lastSunday99999: _getLastSunday99999(),
    );

    final monday = _getMonday(_weekOffset);
    final schedule = solver.solveRolesOnly(monday, _fixedRestPeoplePerDay!, offset: _refreshOffset);

    if (schedule != null) {
      await DatabaseService.saveSchedule(schedule);
      setState(() => _currentSchedule = schedule);
      await _loadHistory();
    } else {
      // 没有更多组合了，回退到完全求解
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有更多组合了'), backgroundColor: Colors.orange),
        );
      }
      _refreshOffset--; // 恢复
    }
  }

  /// 构建导出专用完整排班表（非滚动式，所有天在一行）
  Widget _buildExportSchedule(WeekSchedule schedule) {
    final weekDays = schedule.days.map((d) => d.dayIndex).toList()..sort();
    return Container(
      width: weekDays.length * 155.0 + 32, // 所有天水平排列
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 导出标题
          Text('排班表 - ${_weekLabel(_weekOffset)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text(getDateRange(schedule),
              style: TextStyle(fontSize: 13, color: Colors.grey[600])),
          const SizedBox(height: 12),
          // 所有天卡水平排列（不滚动）
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: weekDays.map((dayIndex) {
              final day = schedule.days.firstWhere((d) => d.dayIndex == dayIndex);
              final dayDate = schedule.weekStart.add(Duration(days: dayIndex));
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
                  border: Border.all(color: isToday ? Colors.blue : Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Text(_dayName(dayIndex),
                        style: TextStyle(fontWeight: FontWeight.bold,
                            fontSize: 14, color: isToday ? Colors.blue : null)),
                    Text('${dayDate.month}/${dayDate.day}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                    if (isToday)
                      const Text('📅', style: TextStyle(fontSize: 12)),
                    const Divider(height: 8),
                    Text('🏦 ${day.person99999}',
                        style: const TextStyle(fontSize: 12)),
                    Text('🤝 ${day.personXieguan}',
                        style: const TextStyle(fontSize: 12)),
                    if (_isUserSpecifiedRestDay(dayIndex, day.personRest))
                      Text('🔴 休班 ${day.personRest}',
                          style: TextStyle(fontSize: 11, color: Colors.orange[800])),
                    if (day.personNoonRest.isNotEmpty)
                      Text('☕ 午休 ${day.personNoonRest}',
                          style: TextStyle(fontSize: 11, color: Colors.brown[600])),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          // 统计
          Text('统计',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          ...schedule.names.map((name) {
            int c9 = 0, cx = 0;
            for (final d in schedule.days) {
              if (d.person99999 == name) c9++;
              if (d.personXieguan == name) cx++;
            }
            return Text('$name: 🏦×$c9  🤝×$cx',
                style: const TextStyle(fontSize: 12));
          }),
        ],
      ),
    );
  }

  Future<void> _exportToImage() async {
    if (_currentSchedule == null) return;

    final schedule = _currentSchedule!;
    final exportKey = GlobalKey();

    // 弹窗显示完整排班表，然后截图
    final captured = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: RepaintBoundary(
            key: exportKey,
            child: _buildExportSchedule(schedule),
          ),
        ),
      ),
    );

    // 弹窗关闭后截图
    try {
      // 用延迟方式：重新弹出纯截图用对话框
      showDialog(
        context: context,
        barrierColor: Colors.transparent,
        builder: (ctx2) {
          final repaintKey = GlobalKey();
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              final boundary = repaintKey.currentContext?.findRenderObject()
                  as RenderRepaintBoundary?;
              if (boundary == null) {
                Navigator.pop(ctx2);
                return;
              }

              final image = await boundary.toImage(pixelRatio: 3.0);
              final byteData = await image.toByteData(
                  format: ui.ImageByteFormat.png);
              final pngBytes = byteData!.buffer.asUint8List();

              Navigator.pop(ctx2);

              final dir = await getTemporaryDirectory();
              final file = File(
                  '${dir.path}/schedule_${DateTime.now().millisecondsSinceEpoch}.png');
              await file.writeAsBytes(pngBytes);

              // 保存到手机相册
              try {
                const channel = MethodChannel('gallery_saver');
                await channel.invokeMethod('saveToGallery',
                    {'filePath': file.path});
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('✅ 排班表已保存到「相册-排班表」文件夹'),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 3),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ 图片已保存到临时目录:\n${file.path}'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              }
            } catch (e) {
              Navigator.pop(ctx2);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text('导出失败: $e'),
                      backgroundColor: Colors.red),
                );
              }
            }
          });
          return RepaintBoundary(
            key: repaintKey,
            child: _buildExportSchedule(schedule),
          );
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('排班App'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_currentSchedule != null)
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: _exportToImage,
              tooltip: '导出排班表',
            ),
        ],
      ),
      body: _currentSchedule == null ? _buildEmptyState() : _buildScheduleView(),
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
                            _generateSchedule();
                          },
                        ),
                      ),
                      const Spacer(),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: _refreshSchedule,
                            icon: const Icon(Icons.refresh, size: 20),
                            tooltip: '刷新角色分配',
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
                    const Text('为下周每位柜员选择休班日：',
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

    final schedule = solver.solve(nextMonday);
    if (schedule != null) {
      // 固定下周的休班日
      final workingDays = schedule.days.map((d) => d.dayIndex).toList()..sort();
      final restIndices = workingDays.map((di) {
        final day = schedule.days.firstWhere((d) => d.dayIndex == di);
        return _names.indexOf(day.personRest);
      }).toList();
      
      await DatabaseService.saveSchedule(schedule);
      setState(() {
        _currentSchedule = schedule;
        _fixedRestPeoplePerDay = restIndices;
        _hasInitialSolve = true;
        _refreshOffset = 0;
        _weekOffset = 1; // 切换到下周
      });
      await _loadHistory();
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

  void _showSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          names: List.from(_names),
          closingDay: _closingDay,
          restDays: List.from(_restDays),
          onSave: (names, closingDay, restDays) async {
            setState(() {
              _names = names;
              _closingDay = closingDay;
              _restDays = restDays;
            });
            await DatabaseService.saveSetting('names', names.join(','));
            await DatabaseService.saveSetting('closing_day', closingDay.toString());
            await DatabaseService.saveSetting('rest_days', restDays.join(','));
            _generateSchedule();
          },
        ),
      ),
    );
  }
}

// ============ 设置页面 ============

class SettingsScreen extends StatefulWidget {
  final List<String> names;
  final int closingDay;
  final List<int> restDays;
  final Function(List<String>, int, List<int>) onSave;

  const SettingsScreen({
    super.key,
    required this.names,
    required this.closingDay,
    required this.restDays,
    required this.onSave,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late List<TextEditingController> _nameControllers;
  late int _closingDay;
  late List<int> _restDays;

  @override
  void initState() {
    super.initState();
    _nameControllers = widget.names.map((n) => TextEditingController(text: n)).toList();
    _closingDay = widget.closingDay;
    _restDays = List.from(widget.restDays);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          TextButton(
            onPressed: () {
              widget.onSave(
                _nameControllers.map((c) => c.text).toList(),
                _closingDay,
                _restDays,
              );
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 柜员姓名设置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('柜员姓名', style: Theme.of(context).textTheme.titleSmall),
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
                  Text('每周关门日', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _closingDay,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
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

          // 休班日设置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('每人休班日', style: Theme.of(context).textTheme.titleSmall),
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
                );
                Navigator.pop(context);
              },
              icon: const Icon(Icons.auto_awesome),
              label: const Text('保存并生成排班', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}
