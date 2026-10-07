import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const ExpenseApp());

// ===================== CONSTANTS & HELPERS =====================

const String rupee = '\u20B9';

const List<String> categories = [
  'Food',
  'Transport',
  'Entertainment',
  'Study',
  'Shopping',
  'Health',
  'Bills',
  'Other',
];

const Color brandDark = Color(0xFF004D40);
const Color brandMid = Color(0xFF00897B);
const Color brandLight = Color(0xFF4DB6AC);

const List<String> monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'
];

String money(double v) => '$rupee ${v.toStringAsFixed(2)}';
String money0(double v) => '$rupee ${v.toStringAsFixed(0)}';
String amountText(double v) => v % 1 == 0 ? v.toStringAsFixed(0) : v.toString();
String formatDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
String monthLabel(DateTime d) => '${monthNames[d.month - 1]} ${d.year}';
String shortMonth(DateTime d) => monthNames[d.month - 1].substring(0, 3);
String capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
String newId() => DateTime.now().microsecondsSinceEpoch.toString();

class CategoryStyle {
  final IconData icon;
  final Color color;
  const CategoryStyle(this.icon, this.color);
}

CategoryStyle styleFor(String category) {
  switch (category.toLowerCase()) {
    case 'food':
      return const CategoryStyle(Icons.restaurant, Color(0xFFFF9800));
    case 'transport':
      return const CategoryStyle(Icons.directions_bus, Color(0xFF2196F3));
    case 'entertainment':
      return const CategoryStyle(Icons.movie, Color(0xFF9C27B0));
    case 'study':
      return const CategoryStyle(Icons.menu_book, Color(0xFF4CAF50));
    case 'shopping':
      return const CategoryStyle(Icons.shopping_bag, Color(0xFFE91E63));
    case 'health':
      return const CategoryStyle(Icons.favorite, Color(0xFFF44336));
    case 'bills':
      return const CategoryStyle(Icons.receipt_long, Color(0xFF795548));
    default:
      return const CategoryStyle(Icons.category, Color(0xFF607D8B));
  }
}

BoxDecoration cardDeco([double radius = 20]) => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    );

// ===================== MODELS =====================

class Expense {
  final String id;
  final String description;
  final double amount;
  final String category;
  final DateTime date;

  Expense({
    String? id,
    required this.description,
    required this.amount,
    required this.category,
    DateTime? date,
  })  : id = id ?? newId(),
        date = date ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'description': description,
        'amount': amount,
        'category': category,
        'date': date.toIso8601String(),
      };

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: j['id'] as String,
        description: j['description'] as String,
        amount: (j['amount'] as num).toDouble(),
        category: j['category'] as String,
        date: DateTime.parse(j['date'] as String),
      );
}

class Repayment {
  final double amount;
  final DateTime date;
  Repayment({required this.amount, required this.date});

  Map<String, dynamic> toJson() =>
      {'amount': amount, 'date': date.toIso8601String()};

  factory Repayment.fromJson(Map<String, dynamic> j) => Repayment(
        amount: (j['amount'] as num).toDouble(),
        date: DateTime.parse(j['date'] as String),
      );
}

class Loan {
  final String id;
  final String friend;
  final double amount;
  final String note;
  final DateTime date;
  final DateTime? due;
  final List<Repayment> repayments;

  Loan({
    String? id,
    required this.friend,
    required this.amount,
    this.note = '',
    DateTime? date,
    this.due,
    List<Repayment>? repayments,
  })  : id = id ?? newId(),
        date = date ?? DateTime.now(),
        repayments = repayments ?? [];

  double get repaid => repayments.fold(0.0, (s, r) => s + r.amount);
  double get pending => math.max(amount - repaid, 0.0);
  bool get settled => pending < 0.005;
  bool get overdue {
    if (settled || due == null) return false;
    final n = DateTime.now();
    return due!.isBefore(DateTime(n.year, n.month, n.day));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'friend': friend,
        'amount': amount,
        'note': note,
        'date': date.toIso8601String(),
        'due': due?.toIso8601String(),
        'repayments': repayments.map((r) => r.toJson()).toList(),
      };

  factory Loan.fromJson(Map<String, dynamic> j) => Loan(
        id: j['id'] as String,
        friend: j['friend'] as String,
        amount: (j['amount'] as num).toDouble(),
        note: (j['note'] as String?) ?? '',
        date: DateTime.parse(j['date'] as String),
        due: j['due'] == null ? null : DateTime.parse(j['due'] as String),
        repayments: ((j['repayments'] as List?) ?? [])
            .map((x) => Repayment.fromJson(x as Map<String, dynamic>))
            .toList(),
      );
}

// ===================== STATS & FORECAST =====================

class Forecast {
  final double total;
  final Map<String, double> byCategory;
  final List<DateTime> months; // history months used
  final bool fromPace; // true = early estimate from this month's pace
  Forecast(this.total, this.byCategory, this.months, this.fromPace);
}

class Stats {
  final List<Expense> all;
  Stats(this.all);

  static DateTime monthStart(int offset) {
    final n = DateTime.now();
    return DateTime(n.year, n.month + offset, 1);
  }

  static DateTime monthEnd(DateTime start) =>
      DateTime(start.year, start.month + 1, 1);

  double totalIn(DateTime from, DateTime to) => all
      .where((e) => !e.date.isBefore(from) && e.date.isBefore(to))
      .fold(0.0, (s, e) => s + e.amount);

  Map<String, double> byCategory(DateTime from, DateTime to) {
    final map = <String, double>{};
    for (final e in all) {
      if (e.date.isBefore(from) || !e.date.isBefore(to)) continue;
      final k = e.category.toLowerCase();
      map[k] = (map[k] ?? 0) + e.amount;
    }
    return map;
  }

  /// Up to the last 3 complete months, starting no earlier than the
  /// month of the very first expense (oldest first).
  List<DateTime> historyMonths({int count = 3}) {
    if (all.isEmpty) return [];
    final first = all.map((e) => e.date).reduce((a, b) => a.isBefore(b) ? a : b);
    final firstMonth = DateTime(first.year, first.month, 1);
    final list = <DateTime>[];
    for (var i = count; i >= 1; i--) {
      final m = monthStart(-i);
      if (!m.isBefore(firstMonth)) list.add(m);
    }
    return list;
  }

  // Weighted average, oldest -> newest, weights 1, 2, 3 ...
  static double weighted(List<double> v) {
    var num = 0.0, den = 0.0;
    for (var i = 0; i < v.length; i++) {
      final w = (i + 1).toDouble();
      num += v[i] * w;
      den += w;
    }
    return den == 0 ? 0 : num / den;
  }

  Forecast? forecast() {
    final months = historyMonths();
    if (months.isNotEmpty) {
      final perMonth =
          months.map((m) => byCategory(m, monthEnd(m))).toList();
      final cats = perMonth.expand((m) => m.keys).toSet();
      final byCat = <String, double>{};
      for (final c in cats) {
        byCat[c] = weighted(perMonth.map((m) => m[c] ?? 0.0).toList());
      }
      final total = byCat.values.fold(0.0, (a, b) => a + b);
      return Forecast(total, byCat, months, false);
    }
    // Fallback: project this month's pace.
    final start = monthStart(0);
    final by = byCategory(start, monthEnd(start));
    if (by.isEmpty) return null;
    final n = DateTime.now();
    final elapsed = math.max(n.day, 1);
    final days = DateTime(n.year, n.month + 1, 0).day;
    final factor = days / elapsed;
    final byCat = by.map((k, v) => MapEntry(k, v * factor));
    final total = byCat.values.fold(0.0, (a, b) => a + b);
    return Forecast(total, byCat, [], true);
  }
}

// ===================== APP =====================

class ExpenseApp extends StatelessWidget {
  const ExpenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Personal Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: brandMid,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF2F6F5),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  bool loading = true;
  List<Expense> expenses = [];
  List<Loan> loans = [];
  double budget = 0;
  String loanFilter = 'pending';

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ---------- storage ----------
  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final e = p.getString('expenses');
      final l = p.getString('loans');
      if (e != null) {
        expenses = (jsonDecode(e) as List)
            .map((x) => Expense.fromJson(x as Map<String, dynamic>))
            .toList();
      }
      if (l != null) {
        loans = (jsonDecode(l) as List)
            .map((x) => Loan.fromJson(x as Map<String, dynamic>))
            .toList();
      }
      budget = p.getDouble('budget') ?? 0;
    } catch (_) {
      // Storage unavailable or corrupted: start empty.
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          'expenses', jsonEncode(expenses.map((e) => e.toJson()).toList()));
      await p.setString(
          'loans', jsonEncode(loans.map((l) => l.toJson()).toList()));
      await p.setDouble('budget', budget);
    } catch (_) {}
  }

  void update(VoidCallback fn) {
    setState(fn);
    _save();
  }

  void toast(String msg, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(msg),
        action: action,
      ));
  }

  // ---------- expenses ----------
  void openExpenseForm({Expense? existing}) {
    showDialog(
      context: context,
      builder: (_) => ExpenseDialog(
        existing: existing,
        onSave: (ex) {
          update(() {
            if (existing == null) {
              expenses.insert(0, ex);
            } else {
              final i = expenses.indexWhere((x) => x.id == existing.id);
              if (i != -1) expenses[i] = ex;
            }
          });
          toast(existing == null ? 'Expense added.' : 'Expense updated.');
        },
      ),
    );
  }

  Future<void> deleteExpense(Expense e) async {
    final ok = await confirmDialog(context,
        title: 'Delete expense?',
        message: '"${e.description}" (${money(e.amount)}) will be removed.');
    if (!ok || !mounted) return;
    final index = expenses.indexWhere((x) => x.id == e.id);
    if (index == -1) return;
    update(() => expenses.removeAt(index));
    toast('${e.description} deleted',
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () => update(
              () => expenses.insert(math.min(index, expenses.length), e)),
        ));
  }

  // ---------- loans ----------
  void openLoanForm({Loan? existing}) {
    showDialog(
      context: context,
      builder: (_) => LoanDialog(
        existing: existing,
        onSave: (loan) {
          update(() {
            if (existing == null) {
              loans.insert(0, loan);
            } else {
              final i = loans.indexWhere((x) => x.id == existing.id);
              if (i != -1) loans[i] = loan;
            }
          });
          toast(existing == null ? 'Loan recorded.' : 'Loan updated.');
        },
      ),
    );
  }

  void openRepayment(Loan l) {
    showDialog(
      context: context,
      builder: (_) => RepaymentDialog(
        loan: l,
        onSave: (r) {
          update(() => l.repayments.add(r));
          toast('Received ${money(r.amount)} from ${l.friend}.');
        },
      ),
    );
  }

  void markReceived(Loan l) {
    final amt = l.pending;
    update(() => l.repayments
        .add(Repayment(amount: amt, date: DateTime.now())));
    toast('${l.friend} has paid back everything.');
  }

  Future<void> deleteLoan(Loan l) async {
    final ok = await confirmDialog(context,
        title: 'Delete this record?',
        message:
            'The ${money(l.amount)} loan to ${l.friend} and its repayment history will be removed.');
    if (!ok || !mounted) return;
    final index = loans.indexWhere((x) => x.id == l.id);
    if (index == -1) return;
    update(() => loans.removeAt(index));
    toast('Record deleted',
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () =>
              update(() => loans.insert(math.min(index, loans.length), l)),
        ));
  }

  // ---------- budget ----------
  void askBudget() {
    showDialog(
      context: context,
      builder: (_) => BudgetDialog(
        initial: budget,
        onSave: (v) {
          update(() => budget = v);
          toast('Monthly budget saved.');
        },
      ),
    );
  }

  void useBudget(double v) {
    update(() => budget = v);
    toast('Budget set to ${money0(v)}.');
  }

  // ---------- build ----------
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final Widget body;
    switch (tab) {
      case 0:
        body = ExpensesTab(
            expenses: expenses,
            onEdit: (e) => openExpenseForm(existing: e),
            onDelete: deleteExpense);
        break;
      case 1:
        body = SummaryTab(expenses: expenses);
        break;
      case 2:
        body = BudgetTab(
            expenses: expenses,
            budget: budget,
            onEdit: askBudget,
            onUse: useBudget);
        break;
      case 3:
        body = ForecastTab(expenses: expenses, budget: budget);
        break;
      default:
        body = LoansTab(
          loans: loans,
          filter: loanFilter,
          onFilter: (f) => setState(() => loanFilter = f),
          onEdit: (l) => openLoanForm(existing: l),
          onDelete: deleteLoan,
          onRepay: openRepayment,
          onFull: markReceived,
        );
    }

    Widget? fab;
    if (tab == 0) {
      fab = FloatingActionButton.extended(
        onPressed: () => openExpenseForm(),
        backgroundColor: brandMid,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add expense'),
      );
    } else if (tab == 4) {
      fab = FloatingActionButton.extended(
        onPressed: () => openLoanForm(),
        backgroundColor: brandMid,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Lend money'),
      );
    }

    return Scaffold(
      body: body,
      floatingActionButton: fab,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.receipt_long), label: 'Expenses'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Summary'),
          NavigationDestination(
              icon: Icon(Icons.account_balance_wallet), label: 'Budget'),
          NavigationDestination(
              icon: Icon(Icons.auto_graph), label: 'Forecast'),
          NavigationDestination(icon: Icon(Icons.group), label: 'Lent'),
        ],
      ),
    );
  }
}

// ===================== SHARED WIDGETS =====================

class GradientHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String label;
  final String value;
  final List<Widget> chips;
  const GradientHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.label,
    required this.value,
    this.chips = const [],
  });

  Widget _circle(double size, double alpha) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: alpha),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [brandDark, brandMid, brandLight],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned(top: -40, right: -30, child: _circle(150, 0.08)),
            Positioned(bottom: -50, left: -40, child: _circle(120, 0.07)),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  22, MediaQuery.of(context).padding.top + 16, 22, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(label,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(value,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 36,
                            fontWeight: FontWeight.bold)),
                  ),
                  if (chips.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Wrap(spacing: 10, runSpacing: 8, children: chips),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HeaderChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const HeaderChip(this.icon, this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const EmptyState(
      {super.key,
      required this.icon,
      required this.title,
      required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: brandMid.withValues(alpha: 0.1),
              ),
              child: Icon(icon, size: 60, color: brandMid),
            ),
            const SizedBox(height: 18),
            Text(title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54)),
          ],
        ),
      ),
    );
  }
}

class CategoryBar extends StatelessWidget {
  final String category;
  final String trailing;
  final double progress;
  final Color? color;
  final String? note;
  const CategoryBar({
    super.key,
    required this.category,
    required this.trailing,
    required this.progress,
    this.color,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final st = styleFor(category);
    final c = color ?? st.color;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: st.color.withValues(alpha: 0.15),
                child: Icon(st.icon, color: st.color, size: 17),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(capitalize(category),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              Text(trailing,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: math.min(math.max(progress, 0.0), 1.0),
              minHeight: 8,
              color: c,
              backgroundColor: c.withValues(alpha: 0.15),
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(note!,
                  style: const TextStyle(color: Colors.black54, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

class DonutPainter extends CustomPainter {
  final List<MapEntry<String, double>> data;
  final double total;
  DonutPainter(this.data, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    const stroke = 26.0;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - stroke / 2,
    );
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.black.withValues(alpha: 0.05);
    canvas.drawArc(rect, 0, math.pi * 2, false, track);

    var start = -math.pi / 2;
    for (final e in data) {
      final sweep = e.value / total * math.pi * 2;
      final gap = data.length > 1 ? 0.05 : 0.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = styleFor(e.key).color;
      canvas.drawArc(rect, start, math.max(sweep - gap, 0.01), false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant DonutPainter old) =>
      old.data != data || old.total != total;
}

class BarItem {
  final String label;
  final double value;
  final Color color;
  BarItem(this.label, this.value, this.color);
}

class MiniBarChart extends StatelessWidget {
  final List<BarItem> items;
  const MiniBarChart({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final maxV = items.fold(0.0, (m, i) => math.max(m, i.value));
    return SizedBox(
      height: 170,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: items.map((i) {
          final h = maxV <= 0 ? 4.0 : math.max(i.value / maxV * 110, 4.0);
          return Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(money0(i.value),
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 4),
                Container(
                  width: 38,
                  height: h,
                  decoration: BoxDecoration(
                    color: i.color,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(10)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(i.label,
                    style: const TextStyle(color: Colors.black54, fontSize: 12)),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ===================== TAB 1: EXPENSES =====================

class ExpensesTab extends StatelessWidget {
  final List<Expense> expenses;
  final void Function(Expense) onEdit;
  final void Function(Expense) onDelete;
  const ExpensesTab(
      {super.key,
      required this.expenses,
      required this.onEdit,
      required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final s = Stats(expenses);
    final total = expenses.fold(0.0, (sum, e) => sum + e.amount);
    final m0 = Stats.monthStart(0);
    final thisMonth = s.totalIn(m0, Stats.monthEnd(m0));
    final sorted = [...expenses]..sort((a, b) {
        final c = b.date.compareTo(a.date);
        return c != 0 ? c : b.id.compareTo(a.id);
      });

    return Column(
      children: [
        GradientHeader(
          icon: Icons.receipt_long,
          title: 'Personal Expense Tracker',
          label: 'Total spent',
          value: money(total),
          chips: [
            HeaderChip(Icons.receipt_long, '${expenses.length} expenses'),
            HeaderChip(Icons.calendar_month, 'This month: ${money0(thisMonth)}'),
          ],
        ),
        Expanded(
          child: expenses.isEmpty
              ? const EmptyState(
                  icon: Icons.savings_outlined,
                  title: 'No expenses yet',
                  message: 'Tap "Add expense" to record your first one.')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 100),
                  itemCount: sorted.length,
                  itemBuilder: (context, index) {
                    final e = sorted[index];
                    final st = styleFor(e.category);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: cardDeco(),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: IntrinsicHeight(
                          child: Row(
                            children: [
                              Container(width: 6, color: st.color),
                              Expanded(
                                child: ListTile(
                                  onTap: () => onEdit(e),
                                  contentPadding:
                                      const EdgeInsets.only(left: 14, right: 2),
                                  leading: CircleAvatar(
                                    radius: 24,
                                    backgroundColor:
                                        st.color.withValues(alpha: 0.15),
                                    child: Icon(st.icon, color: st.color),
                                  ),
                                  title: Text(e.description,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16)),
                                  subtitle: Text(
                                      '${capitalize(e.category)}  \u2022  ${formatDate(e.date)}'),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(money(e.amount),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15)),
                                      PopupMenuButton<String>(
                                        tooltip: 'More options',
                                        icon: const Icon(Icons.more_vert),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(16)),
                                        onSelected: (v) {
                                          if (v == 'edit') onEdit(e);
                                          if (v == 'delete') onDelete(e);
                                        },
                                        itemBuilder: (_) =>
                                            <PopupMenuEntry<String>>[
                                          const PopupMenuItem(
                                            value: 'edit',
                                            child: Row(children: [
                                              Icon(Icons.edit, size: 20),
                                              SizedBox(width: 10),
                                              Text('Edit'),
                                            ]),
                                          ),
                                          const PopupMenuItem(
                                            value: 'delete',
                                            child: Row(children: [
                                              Icon(Icons.delete,
                                                  size: 20, color: Colors.red),
                                              SizedBox(width: 10),
                                              Text('Delete',
                                                  style: TextStyle(
                                                      color: Colors.red)),
                                            ]),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ===================== TAB 2: SUMMARY (daily / weekly / monthly) =====================

enum Period { day, week, month }

class SummaryTab extends StatefulWidget {
  final List<Expense> expenses;
  const SummaryTab({super.key, required this.expenses});

  @override
  State<SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends State<SummaryTab> {
  Period period = Period.week;
  int offset = 0; // 0 = current period, -1 = previous, ...

  (DateTime, DateTime) range() {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    switch (period) {
      case Period.day:
        final s = DateTime(today.year, today.month, today.day + offset);
        return (s, DateTime(s.year, s.month, s.day + 1));
      case Period.week:
        final mon = DateTime(today.year, today.month,
            today.day - (today.weekday - 1) + offset * 7);
        return (mon, DateTime(mon.year, mon.month, mon.day + 7));
      case Period.month:
        final s = DateTime(today.year, today.month + offset, 1);
        return (s, DateTime(s.year, s.month + 1, 1));
    }
  }

  String label(DateTime from, DateTime to) {
    switch (period) {
      case Period.day:
        if (offset == 0) return 'Today';
        if (offset == -1) return 'Yesterday';
        return formatDate(from);
      case Period.week:
        if (offset == 0) return 'This week';
        final last = DateTime(to.year, to.month, to.day - 1);
        return '${formatDate(from)}  to  ${formatDate(last)}';
      case Period.month:
        return monthLabel(from);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (from, to) = range();
    final s = Stats(widget.expenses);
    final byCat = s.byCategory(from, to);
    final entries = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold(0.0, (sum, e) => sum + e.value);
    final count = widget.expenses
        .where((e) => !e.date.isBefore(from) && e.date.isBefore(to))
        .length;

    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final fullDays = to.difference(from).inDays;
    final elapsed = offset == 0
        ? math.max(math.min(today.difference(from).inDays + 1, fullDays), 1)
        : math.max(fullDays, 1);
    final perDay = total / elapsed;

    return Column(
      children: [
        GradientHeader(
          icon: Icons.bar_chart,
          title: 'Spending summary',
          label: label(from, to),
          value: money(total),
          chips: [
            HeaderChip(Icons.receipt_long, '$count expenses'),
            HeaderChip(Icons.today, '${money0(perDay)} / day'),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<Period>(
                  segments: const [
                    ButtonSegment(value: Period.day, label: Text('Daily')),
                    ButtonSegment(value: Period.week, label: Text('Weekly')),
                    ButtonSegment(value: Period.month, label: Text('Monthly')),
                  ],
                  selected: {period},
                  onSelectionChanged: (sel) => setState(() {
                    period = sel.first;
                    offset = 0;
                  }),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() => offset--),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(label(from, to),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    onPressed: offset >= 0 ? null : () => setState(() => offset++),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: const EmptyState(
                      icon: Icons.insights,
                      title: 'Nothing spent here',
                      message: 'No expenses were recorded in this period.'),
                )
              else ...[
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: cardDeco(24),
                  child: Column(
                    children: [
                      const Text('Spending by category',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 200,
                        width: 200,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CustomPaint(
                              size: const Size(200, 200),
                              painter: DonutPainter(entries, total),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Total',
                                    style: TextStyle(color: Colors.black54)),
                                Text(money0(total),
                                    style: const TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
                  decoration: cardDeco(),
                  child: Column(
                    children: entries.map((e) {
                      final share = total == 0 ? 0.0 : e.value / total;
                      return CategoryBar(
                        category: e.key,
                        trailing: money(e.value),
                        progress: share,
                        note: '${(share * 100).toStringAsFixed(1)}% of total',
                      );
                    }).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ===================== TAB 3: BUDGET PLANNER =====================

class BudgetTab extends StatelessWidget {
  final List<Expense> expenses;
  final double budget;
  final VoidCallback onEdit;
  final void Function(double) onUse;
  const BudgetTab(
      {super.key,
      required this.expenses,
      required this.budget,
      required this.onEdit,
      required this.onUse});

  @override
  Widget build(BuildContext context) {
    final s = Stats(expenses);
    final now = DateTime.now();
    final start = Stats.monthStart(0);
    final end = Stats.monthEnd(start);
    final spent = s.totalIn(start, end);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final daysLeft = daysInMonth - now.day + 1;
    final remaining = budget - spent;
    final pct = budget > 0 ? spent / budget : 0.0;
    final projected = spent / math.max(now.day, 1) * daysInMonth;

    final months = s.historyMonths();
    final monthTotals =
        months.map((m) => s.totalIn(m, Stats.monthEnd(m))).toList();
    final avg = monthTotals.isEmpty
        ? null
        : monthTotals.fold(0.0, (a, b) => a + b) / monthTotals.length;
    final suggested =
        (avg == null || avg <= 0) ? null : (avg / 100).ceil() * 100.0;

    final statusColor = pct < 0.75
        ? Colors.green
        : (pct < 1 ? Colors.orange : Colors.red);

    // Category plan = budget split by each category's share of past spending.
    final plan = <String, double>{};
    if (budget > 0 && avg != null && avg > 0) {
      final catAvg = <String, double>{};
      for (final m in months) {
        s.byCategory(m, Stats.monthEnd(m)).forEach((k, v) {
          catAvg[k] = (catAvg[k] ?? 0) + v / months.length;
        });
      }
      catAvg.forEach((k, v) => plan[k] = budget * v / avg);
    }
    final spentBy = s.byCategory(start, end);
    final keys = {...plan.keys, ...spentBy.keys}.toList()
      ..sort((a, b) => (plan[b] ?? 0).compareTo(plan[a] ?? 0));

    return Column(
      children: [
        GradientHeader(
          icon: Icons.account_balance_wallet,
          title: 'Monthly budget planner',
          label: monthLabel(start),
          value: budget > 0 ? money0(budget) : 'Not set',
          chips: [
            HeaderChip(Icons.shopping_cart_checkout, 'Spent: ${money0(spent)}'),
            if (budget > 0)
              HeaderChip(
                  remaining >= 0 ? Icons.savings : Icons.warning_amber,
                  remaining >= 0
                      ? 'Left: ${money0(remaining)}'
                      : 'Over: ${money0(-remaining)}'),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
            children: [
              if (budget <= 0)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: cardDeco(),
                  child: Column(
                    children: [
                      const Icon(Icons.flag, size: 40, color: brandMid),
                      const SizedBox(height: 10),
                      const Text('Set your budget for this month',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                          suggested != null
                              ? 'Based on your last ${months.length} month(s), we suggest ${money0(suggested)}.'
                              : 'Add expenses over a few months and we will suggest a budget for you.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.black54)),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                                onPressed: onEdit,
                                child: const Text('Enter amount')),
                          ),
                          if (suggested != null) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                  onPressed: () => onUse(suggested),
                                  child: Text('Use ${money0(suggested)}')),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                )
              else ...[
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: cardDeco(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text('This month so far',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                          ),
                          TextButton.icon(
                              onPressed: onEdit,
                              icon: const Icon(Icons.edit, size: 18),
                              label: const Text('Change')),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: math.min(pct, 1.0),
                          minHeight: 14,
                          color: statusColor,
                          backgroundColor: statusColor.withValues(alpha: 0.15),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('${money(spent)} spent'),
                          Text('${(pct * 100).toStringAsFixed(0)}% used',
                              style: TextStyle(
                                  color: statusColor,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const Divider(height: 28),
                      _tip(
                          remaining >= 0 ? Icons.today : Icons.warning_amber,
                          remaining >= 0
                              ? 'You can spend about ${money0(remaining / daysLeft)} per day for the remaining $daysLeft day(s).'
                              : 'You are ${money0(-remaining)} over budget this month.',
                          remaining >= 0 ? Colors.green : Colors.red),
                      const SizedBox(height: 10),
                      _tip(
                          projected > budget
                              ? Icons.trending_up
                              : Icons.check_circle,
                          projected > budget
                              ? 'At this pace you will reach ${money0(projected)} by month end, ${money0(projected - budget)} over budget.'
                              : 'At this pace you will finish near ${money0(projected)}, within budget.',
                          projected > budget ? Colors.orange : Colors.green),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
                  decoration: cardDeco(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Category plan vs spent',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                          plan.isEmpty
                              ? 'A category plan appears after you have at least one full month of expenses.'
                              : 'Your budget is split using what you spent in past months.',
                          style: const TextStyle(
                              color: Colors.black54, fontSize: 12)),
                      const SizedBox(height: 14),
                      if (keys.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 14),
                          child: Text('No spending yet this month.'),
                        )
                      else
                        ...keys.map((k) {
                          final p = plan[k] ?? 0;
                          final sp = spentBy[k] ?? 0;
                          final over = p > 0 && sp > p;
                          return CategoryBar(
                            category: k,
                            trailing: p > 0
                                ? '${money0(sp)} / ${money0(p)}'
                                : money0(sp),
                            progress: p > 0 ? sp / p : 0,
                            color: over ? Colors.red : null,
                            note: p <= 0
                                ? 'No plan for this category'
                                : (over
                                    ? 'Over plan by ${money0(sp - p)}'
                                    : '${money0(p - sp)} left'),
                          );
                        }),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: cardDeco(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Last few months',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    if (months.isEmpty)
                      const Text(
                          'No completed months yet. Keep adding expenses and history will show here.',
                          style: TextStyle(color: Colors.black54))
                    else ...[
                      for (var i = 0; i < months.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(monthLabel(months[i])),
                              Text(money(monthTotals[i]),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      const Divider(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Average per month',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          Text(money(avg ?? 0),
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      if (suggested != null && budget > 0 && suggested != budget)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                              onPressed: () => onUse(suggested),
                              child: Text('Use suggested ${money0(suggested)}')),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tip(IconData icon, String text, Color color) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      );
}

// ===================== TAB 4: FORECAST =====================

class ForecastTab extends StatelessWidget {
  final List<Expense> expenses;
  final double budget;
  const ForecastTab({super.key, required this.expenses, required this.budget});

  @override
  Widget build(BuildContext context) {
    final s = Stats(expenses);
    final f = s.forecast();
    final next = Stats.monthStart(1);

    if (f == null) {
      return Column(
        children: [
          GradientHeader(
            icon: Icons.auto_graph,
            title: 'Next month forecast',
            label: monthLabel(next),
            value: '--',
          ),
          const Expanded(
            child: EmptyState(
                icon: Icons.auto_graph,
                title: 'Not enough data yet',
                message:
                    'Add some expenses and we will predict next month\'s spending.'),
          ),
        ],
      );
    }

    final m0 = Stats.monthStart(0);
    final items = <BarItem>[];
    if (f.fromPace) {
      items.add(BarItem(
          'This month', s.totalIn(m0, Stats.monthEnd(m0)), brandLight));
    } else {
      for (final m in f.months) {
        items.add(BarItem(shortMonth(m), s.totalIn(m, Stats.monthEnd(m)),
            brandLight));
      }
    }
    items.add(BarItem(shortMonth(next), f.total, Colors.orange));

    double? change;
    if (!f.fromPace && items.length >= 2) {
      final last = items[items.length - 2].value;
      if (last > 0) change = (f.total - last) / last * 100;
    }

    final entries = f.byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      children: [
        GradientHeader(
          icon: Icons.auto_graph,
          title: 'Next month forecast',
          label: 'Predicted spending in ${monthLabel(next)}',
          value: money0(f.total),
          chips: [
            HeaderChip(
                Icons.history,
                f.fromPace
                    ? 'Early estimate'
                    : 'Based on ${f.months.length} month(s)'),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: cardDeco(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Past months vs prediction',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 14),
                    MiniBarChart(items: items),
                    const SizedBox(height: 8),
                    const Row(
                      children: [
                        Icon(Icons.circle, size: 10, color: brandLight),
                        SizedBox(width: 6),
                        Text('Actual', style: TextStyle(fontSize: 12)),
                        SizedBox(width: 16),
                        Icon(Icons.circle, size: 10, color: Colors.orange),
                        SizedBox(width: 6),
                        Text('Predicted', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: cardDeco(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Insights',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    if (change != null)
                      _line(
                          change >= 0 ? Icons.trending_up : Icons.trending_down,
                          '${change.abs().toStringAsFixed(1)}% ${change >= 0 ? 'higher' : 'lower'} than last month.',
                          change >= 0 ? Colors.orange : Colors.green),
                    if (budget > 0) ...[
                      const SizedBox(height: 8),
                      _line(
                          f.total > budget
                              ? Icons.warning_amber
                              : Icons.check_circle,
                          f.total > budget
                              ? 'Predicted spending is ${money0(f.total - budget)} above your ${money0(budget)} budget. Consider raising it or cutting back.'
                              : 'Predicted spending is ${money0(budget - f.total)} under your ${money0(budget)} budget.',
                          f.total > budget ? Colors.red : Colors.green),
                    ],
                    if (change == null && budget <= 0)
                      _line(
                          Icons.info_outline,
                          'Set a monthly budget in the Budget tab to compare it with this prediction.',
                          Colors.blueGrey),
                    const SizedBox(height: 8),
                    _line(
                        Icons.info_outline,
                        f.fromPace
                            ? 'Early estimate from this month\'s spending pace. It becomes more accurate after a few full months of data.'
                            : 'Weighted average of your last ${f.months.length} month(s); recent months count more.',
                        Colors.blueGrey),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
                decoration: cardDeco(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Predicted by category',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 14),
                    ...entries.map((e) {
                      final share = f.total == 0 ? 0.0 : e.value / f.total;
                      return CategoryBar(
                        category: e.key,
                        trailing: money0(e.value),
                        progress: share,
                        note: '${(share * 100).toStringAsFixed(1)}% of forecast',
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _line(IconData icon, String text, Color color) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      );
}

// ===================== TAB 5: LENT MONEY (friends) =====================

class LoansTab extends StatelessWidget {
  final List<Loan> loans;
  final String filter;
  final void Function(String) onFilter;
  final void Function(Loan) onEdit;
  final void Function(Loan) onDelete;
  final void Function(Loan) onRepay;
  final void Function(Loan) onFull;
  const LoansTab({
    super.key,
    required this.loans,
    required this.filter,
    required this.onFilter,
    required this.onEdit,
    required this.onDelete,
    required this.onRepay,
    required this.onFull,
  });

  static const palette = [
    Color(0xFF3F51B5),
    Color(0xFF009688),
    Color(0xFFE91E63),
    Color(0xFFFF9800),
    Color(0xFF9C27B0),
    Color(0xFF795548),
  ];

  @override
  Widget build(BuildContext context) {
    final totalLent = loans.fold(0.0, (s, l) => s + l.amount);
    final toCollect = loans.fold(0.0, (s, l) => s + l.pending);
    final pendingCount = loans.where((l) => !l.settled).length;
    final overdueCount = loans.where((l) => l.overdue).length;

    final shown = loans.where((l) {
      if (filter == 'pending') return !l.settled;
      if (filter == 'settled') return l.settled;
      return true;
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return Column(
      children: [
        GradientHeader(
          icon: Icons.group,
          title: 'Money lent to friends',
          label: 'To collect back',
          value: money(toCollect),
          chips: [
            HeaderChip(Icons.hourglass_bottom, '$pendingCount pending'),
            HeaderChip(Icons.north_east, 'Lent: ${money0(totalLent)}'),
            if (overdueCount > 0)
              HeaderChip(Icons.error_outline, '$overdueCount overdue'),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'pending', label: Text('Pending')),
                ButtonSegment(value: 'settled', label: Text('Settled')),
                ButtonSegment(value: 'all', label: Text('All')),
              ],
              selected: {filter},
              onSelectionChanged: (sel) => onFilter(sel.first),
            ),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: Icons.handshake_outlined,
                  title: loans.isEmpty
                      ? 'No money lent yet'
                      : (filter == 'pending'
                          ? 'Nothing to collect'
                          : 'No records here'),
                  message: loans.isEmpty
                      ? 'Tap "Lend money" to track money you gave a friend.'
                      : 'Change the filter above to see other records.')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
                  itemCount: shown.length,
                  itemBuilder: (context, i) => _card(context, shown[i]),
                ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, Loan l) {
    final color = palette[l.friend.codeUnits.fold(0, (a, b) => a + b) %
        palette.length];
    final progress = l.amount == 0 ? 0.0 : l.repaid / l.amount;
    final statusColor =
        l.settled ? Colors.green : (l.overdue ? Colors.red : Colors.orange);
    final statusText = l.settled ? 'Settled' : (l.overdue ? 'Overdue' : 'Pending');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: cardDeco(),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => showHistory(context, l),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 4, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Text(
                        l.friend.isEmpty ? '?' : l.friend[0].toUpperCase(),
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 18)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.friend,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                        Text(
                            l.note.isEmpty
                                ? 'Lent on ${formatDate(l.date)}'
                                : '${l.note}  \u2022  ${formatDate(l.date)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.black54, fontSize: 13)),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(statusText,
                        style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 12)),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More options',
                    icon: const Icon(Icons.more_vert),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    onSelected: (v) {
                      if (v == 'repay') onRepay(l);
                      if (v == 'full') onFull(l);
                      if (v == 'edit') onEdit(l);
                      if (v == 'delete') onDelete(l);
                    },
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      if (!l.settled)
                        const PopupMenuItem(
                          value: 'repay',
                          child: Row(children: [
                            Icon(Icons.payments, size: 20),
                            SizedBox(width: 10),
                            Text('Record repayment'),
                          ]),
                        ),
                      if (!l.settled)
                        const PopupMenuItem(
                          value: 'full',
                          child: Row(children: [
                            Icon(Icons.check_circle,
                                size: 20, color: Colors.green),
                            SizedBox(width: 10),
                            Text('Mark fully received'),
                          ]),
                        ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(children: [
                          Icon(Icons.edit, size: 20),
                          SizedBox(width: 10),
                          Text('Edit'),
                        ]),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(children: [
                          Icon(Icons.delete, size: 20, color: Colors.red),
                          SizedBox(width: 10),
                          Text('Delete', style: TextStyle(color: Colors.red)),
                        ]),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: math.min(math.max(progress, 0.0), 1.0),
                        minHeight: 8,
                        color: Colors.green,
                        backgroundColor: Colors.green.withValues(alpha: 0.15),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Lent ${money0(l.amount)}',
                            style: const TextStyle(fontSize: 13)),
                        Text('Received ${money0(l.repaid)}',
                            style: const TextStyle(
                                fontSize: 13, color: Colors.green)),
                        Text('Pending ${money0(l.pending)}',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: l.settled ? Colors.green : statusColor)),
                      ],
                    ),
                    if (l.due != null && !l.settled)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Due on ${formatDate(l.due!)}',
                            style: TextStyle(
                                fontSize: 12,
                                color: l.overdue ? Colors.red : Colors.black54)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void showHistory(BuildContext context, Loan l) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('${l.friend}  \u2022  ${money0(l.amount)}'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Lent on ${formatDate(l.date)}'),
            if (l.note.isNotEmpty) Text('Note: ${l.note}'),
            const Divider(height: 24),
            const Text('Repayments',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (l.repayments.isEmpty)
              const Text('Nothing received yet.',
                  style: TextStyle(color: Colors.black54))
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: l.repayments
                      .map((r) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(formatDate(r.date)),
                                Text(money(r.amount),
                                    style: const TextStyle(
                                        color: Colors.green,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Still to collect',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                Text(money(l.pending),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
}

// ===================== DIALOGS =====================

Future<bool> confirmDialog(BuildContext context,
    {required String title,
    required String message,
    String action = 'Delete'}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      icon: const Icon(Icons.delete_forever, color: Colors.red, size: 36),
      title: Text(title),
      content: Text(message, textAlign: TextAlign.center),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

InputDecoration fieldDeco(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: brandMid),
      filled: true,
      fillColor: const Color(0xFFF5F8F7),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );

/// Keeps only numbers in a text field. Letters, symbols and spaces are removed,
/// including when text is pasted (for example "Rs. 5,000 abc" becomes "5000").
/// Set allowDecimal to keep one decimal point with up to 2 decimal places.
class NumberOnlyFormatter extends TextInputFormatter {
  final bool allowDecimal;
  const NumberOnlyFormatter({this.allowDecimal = false});

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var text = newValue.text;
    if (allowDecimal) {
      text = text.replaceAll(RegExp(r'[^0-9.]'), '');
      final dot = text.indexOf('.');
      if (dot != -1) {
        final whole = text.substring(0, dot);
        var frac = text.substring(dot + 1).replaceAll('.', '');
        if (frac.length > 2) frac = frac.substring(0, 2);
        text = '$whole.$frac';
      }
    } else {
      text = text.replaceAll(RegExp(r'[^0-9]'), '');
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

String? amountError(String? v) {
  final a = double.tryParse((v ?? '').trim());
  if (a == null || a.isNaN || a.isInfinite) {
    return 'Invalid amount. Enter a number, e.g. 199.99.';
  }
  if (a <= 0) return 'Amount must be greater than zero.';
  return null;
}

Future<DateTime?> pickDate(BuildContext context, DateTime initial) =>
    showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );

Widget dateField(String label, DateTime? value, VoidCallback onTap,
    {VoidCallback? onClear}) {
  return InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: onTap,
    child: InputDecorator(
      decoration: fieldDeco(label, Icons.calendar_today).copyWith(
        suffixIcon: (onClear != null && value != null)
            ? IconButton(icon: const Icon(Icons.clear), onPressed: onClear)
            : null,
      ),
      child: Text(value == null ? 'Not set' : formatDate(value),
          style: const TextStyle(fontSize: 16)),
    ),
  );
}

Widget dialogActions(BuildContext context, String label, VoidCallback onPressed) {
  return Row(
    children: [
      Expanded(
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        flex: 2,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: brandMid,
            minimumSize: const Size.fromHeight(50),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
      ),
    ],
  );
}

class DialogShell extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const DialogShell(
      {super.key, required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 18, 8, 18),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [brandDark, brandLight],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(icon, color: Colors.white, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
              Padding(padding: const EdgeInsets.all(20), child: child),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- Add / edit expense ----------

class ExpenseDialog extends StatefulWidget {
  final Expense? existing;
  final void Function(Expense) onSave;
  const ExpenseDialog({super.key, this.existing, required this.onSave});

  @override
  State<ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends State<ExpenseDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _description;
  late final TextEditingController _amount;
  String? _category;
  late DateTime _date;

  bool get isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _description = TextEditingController(text: e?.description ?? '');
    _amount = TextEditingController(text: e == null ? '' : amountText(e.amount));
    _date = e?.date ?? DateTime.now();
    if (e != null) {
      _category = categories.firstWhere(
        (c) => c.toLowerCase() == e.category.toLowerCase(),
        orElse: () => 'Other',
      );
    }
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  void submit() {
    if (!_formKey.currentState!.validate()) return;
    widget.onSave(Expense(
      id: widget.existing?.id,
      description: _description.text.trim(),
      amount: double.parse(_amount.text.trim()),
      category: _category!,
      date: _date,
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return DialogShell(
      title: isEdit ? 'Edit expense' : 'Add expense',
      icon: isEdit ? Icons.edit_note : Icons.add_card,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _description,
              textCapitalization: TextCapitalization.sentences,
              decoration: fieldDeco('Description', Icons.edit),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Description cannot be empty.'
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: fieldDeco('Amount', Icons.currency_rupee),
              validator: amountError,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _category,
              isExpanded: true,
              borderRadius: BorderRadius.circular(16),
              decoration: fieldDeco('Category', Icons.category),
              hint: const Text('Select a category'),
              items: categories
                  .map((c) => DropdownMenuItem<String>(
                        value: c,
                        child: Row(
                          children: [
                            Icon(styleFor(c).icon,
                                size: 20, color: styleFor(c).color),
                            const SizedBox(width: 10),
                            Text(c),
                          ],
                        ),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _category = v),
              validator: (v) => v == null ? 'Please select a category.' : null,
            ),
            const SizedBox(height: 14),
            dateField('Date', _date, () async {
              final p = await pickDate(context, _date);
              if (p != null) setState(() => _date = p);
            }),
            const SizedBox(height: 22),
            dialogActions(
                context, isEdit ? 'Update expense' : 'Save expense', submit),
          ],
        ),
      ),
    );
  }
}

// ---------- Lend money ----------

class LoanDialog extends StatefulWidget {
  final Loan? existing;
  final void Function(Loan) onSave;
  const LoanDialog({super.key, this.existing, required this.onSave});

  @override
  State<LoanDialog> createState() => _LoanDialogState();
}

class _LoanDialogState extends State<LoanDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _friend;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late DateTime _date;
  DateTime? _due;

  bool get isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final l = widget.existing;
    _friend = TextEditingController(text: l?.friend ?? '');
    _amount = TextEditingController(text: l == null ? '' : amountText(l.amount));
    _note = TextEditingController(text: l?.note ?? '');
    _date = l?.date ?? DateTime.now();
    _due = l?.due;
  }

  @override
  void dispose() {
    _friend.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void submit() {
    if (!_formKey.currentState!.validate()) return;
    widget.onSave(Loan(
      id: widget.existing?.id,
      friend: _friend.text.trim(),
      amount: double.parse(_amount.text.trim()),
      note: _note.text.trim(),
      date: _date,
      due: _due,
      repayments: widget.existing?.repayments,
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final received = widget.existing?.repaid ?? 0.0;
    return DialogShell(
      title: isEdit ? 'Edit loan' : 'Lend money',
      icon: Icons.person_add_alt_1,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _friend,
              textCapitalization: TextCapitalization.words,
              decoration: fieldDeco('Friend\'s name', Icons.person),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Please enter your friend\'s name.'
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: fieldDeco('Amount lent', Icons.currency_rupee),
              validator: (v) {
                final err = amountError(v);
                if (err != null) return err;
                final a = double.parse(v!.trim());
                if (a < received) {
                  return 'Cannot be less than ${money(received)} already received.';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _note,
              textCapitalization: TextCapitalization.sentences,
              decoration: fieldDeco('Note (optional)', Icons.notes),
            ),
            const SizedBox(height: 14),
            dateField('Date lent', _date, () async {
              final p = await pickDate(context, _date);
              if (p != null) setState(() => _date = p);
            }),
            const SizedBox(height: 14),
            dateField('Expected back by (optional)', _due, () async {
              final p = await pickDate(context, _due ?? DateTime.now());
              if (p != null) setState(() => _due = p);
            }, onClear: () => setState(() => _due = null)),
            const SizedBox(height: 22),
            dialogActions(context, isEdit ? 'Update' : 'Save loan', submit),
          ],
        ),
      ),
    );
  }
}

// ---------- Record repayment ----------

class RepaymentDialog extends StatefulWidget {
  final Loan loan;
  final void Function(Repayment) onSave;
  const RepaymentDialog({super.key, required this.loan, required this.onSave});

  @override
  State<RepaymentDialog> createState() => _RepaymentDialogState();
}

class _RepaymentDialogState extends State<RepaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: amountText(widget.loan.pending));
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void submit() {
    if (!_formKey.currentState!.validate()) return;
    widget.onSave(
        Repayment(amount: double.parse(_amount.text.trim()), date: _date));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.loan.pending;
    return DialogShell(
      title: 'Record repayment',
      icon: Icons.payments,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.loan.friend} still owes you ${money(pending)}.',
                style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 14),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: fieldDeco('Amount received', Icons.currency_rupee),
              validator: (v) {
                final err = amountError(v);
                if (err != null) return err;
                if (double.parse(v!.trim()) > pending + 0.005) {
                  return 'Cannot be more than the pending ${money(pending)}.';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            dateField('Date received', _date, () async {
              final p = await pickDate(context, _date);
              if (p != null) setState(() => _date = p);
            }),
            const SizedBox(height: 22),
            dialogActions(context, 'Save repayment', submit),
          ],
        ),
      ),
    );
  }
}

// ---------- Budget ----------

class BudgetDialog extends StatefulWidget {
  final double initial;
  final void Function(double) onSave;
  const BudgetDialog({super.key, required this.initial, required this.onSave});

  @override
  State<BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<BudgetDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(
        text: widget.initial > 0 ? amountText(widget.initial) : '');
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void submit() {
    if (!_formKey.currentState!.validate()) return;
    widget.onSave(double.parse(_amount.text.trim()));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return DialogShell(
      title: 'Monthly budget',
      icon: Icons.account_balance_wallet,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('How much do you plan to spend each month?'),
            const SizedBox(height: 14),
            TextFormField(
              controller: _amount,
              autofocus: true,
              keyboardType: TextInputType.number,
              // Only digits are kept; pasted text is cleaned automatically.
              inputFormatters: [
                const NumberOnlyFormatter(),
                LengthLimitingTextInputFormatter(9),
              ],
              decoration: fieldDeco('Budget amount', Icons.currency_rupee),
              validator: amountError,
            ),
            const SizedBox(height: 22),
            dialogActions(context, 'Save budget', submit),
          ],
        ),
      ),
    );
  }
}