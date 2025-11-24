import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:skill_up/features/home/data/task_api.dart';
import 'package:skill_up/features/home/domain/medal_utils.dart';

class PlanOverviewArgs {
  const PlanOverviewArgs({
    required this.planId,
    required this.token,
    required this.tasks,
    this.prompt,
    this.deleteOnly = false,
  });

  final int planId;
  final String token;
  final List<RemoteTask> tasks;
  final String? prompt;
  final bool deleteOnly;
}

enum PlanDecision { accepted, declined }

class PlanOverviewPage extends StatefulWidget {
  const PlanOverviewPage({super.key, required this.args});

  static const route = '/planOverview';

  final PlanOverviewArgs args;

  @override
  State<PlanOverviewPage> createState() => _PlanOverviewPageState();
}

class _PlanOverviewPageState extends State<PlanOverviewPage> {
  final TaskApi _taskApi = TaskApi();
  bool _processing = false;
  String? _error;

  late final Map<DateTime, List<RemoteTask>> _tasksByDay;
  late final List<DateTime> _sortedDays;

  @override
  void initState() {
    super.initState();
    _tasksByDay = _groupTasks(widget.args.tasks);
    _sortedDays = _tasksByDay.keys.toList()..sort();
  }

  @override
  void dispose() {
    _taskApi.close();
    super.dispose();
  }

  Map<DateTime, List<RemoteTask>> _groupTasks(List<RemoteTask> tasks) {
    final grouped = <DateTime, List<RemoteTask>>{};
    for (final task in tasks) {
      final day = dateOnly(task.deadline);
      grouped.putIfAbsent(day, () => <RemoteTask>[]).add(task);
    }
    for (final entry in grouped.entries) {
      entry.value.sort((a, b) => a.deadline.compareTo(b.deadline));
    }
    return grouped;
  }

  Future<void> _handleAccept() async {
    if (!mounted) return;
    Navigator.of(context).pop<PlanDecision>(PlanDecision.accepted);
  }

  Future<void> _handleDecline() async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    final ok = await _taskApi.deletePlan(
      token: widget.args.token,
      planId: widget.args.planId,
    );
    if (!mounted) return;
    setState(() => _processing = false);
    if (!ok) {
      setState(() => _error = 'Unable to discard this plan. Please retry.');
      return;
    }
    Navigator.of(context).pop<PlanDecision>(PlanDecision.declined);
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('EEE, dd MMM');
    final tasksCount = widget.args.tasks.length;
    final start = _sortedDays.isNotEmpty ? _sortedDays.first : null;
    final end = _sortedDays.isNotEmpty ? _sortedDays.last : null;
    final span = start != null && end != null
        ? '${dateFmt.format(start)} → ${dateFmt.format(end)}'
        : 'Upcoming days';

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent, // Set to transparent to show the gradient
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: _BackPill(onTap: () => Navigator.of(context).maybePop()),
      ),
      body: Stack(
        children: [
          const _GradientBackground(), // Custom gradient background
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Header(planId: widget.args.planId),
                        const SizedBox(height: 28),
                        _SummaryCard(
                          totalTasks: tasksCount,
                          timeSpan: span,
                          prompt: widget.args.prompt,
                        ),
                        const SizedBox(height: 18),
                        Container(
                          margin: const EdgeInsets.only(bottom: 24.0),
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: _TaskTimeline(tasksByDay: _tasksByDay),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Text(
                              _error!,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Colors.redAccent,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                _ActionButtons(
                  loading: _processing,
                  onAccept: widget.args.deleteOnly ? null : _handleAccept,
                  onDecline: _handleDecline,
                  deleteOnly: widget.args.deleteOnly,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Helper Widgets ---

class _GradientBackground extends StatelessWidget {
  const _GradientBackground();

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFFFFB3A7), // Top Pink
              Color(0xFFFFE0D9), // Middle Lighter
              Color(0xFFFFCF71), // Bottom Orange
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      ),
    );
  }
}

class _BackPill extends StatelessWidget {
  const _BackPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(28),
        ),
        child: Ink(
          width: 72,
          height: 56,
          decoration: BoxDecoration(
            color: const Color(0xFFB3B3B3),
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(28),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Image.asset(
                'assets/icons/back.png',
                width: 32,
                height: 32,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.planId});

  final int planId;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.white,
      letterSpacing: 1.2,
    );
    return Center(
      child: Column(
        children: [
          Text(
            'OVERVIEW OF YOUR PLAN',
            textAlign: TextAlign.center,
            style: titleStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'Plan #$planId',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.totalTasks,
    required this.timeSpan,
    this.prompt,
  });

  final int totalTasks;
  final String timeSpan;
  final String? prompt;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.16),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$totalTasks tasks scheduled',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            timeSpan,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withOpacity(0.9),
                  fontWeight: FontWeight.w600,
                ),
          ),
          if (prompt != null && prompt!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Goal',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              prompt!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskTimeline extends StatelessWidget {
  const _TaskTimeline({required this.tasksByDay});

  final Map<DateTime, List<RemoteTask>> tasksByDay;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('EEE, dd MMM');
    final entries = tasksByDay.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: entries.map((entry) {
        final date = entry.key;
        final tasks = entry.value;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dateFmt.format(date),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
              ),
              const SizedBox(height: 8),
              ...tasks.map(
                (task) => _TaskRow(task: task),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final RemoteTask task;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            task.description,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.black87,
                ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _Tag(
                label: 'Difficulty ${task.difficulty}',
                color: _difficultyColor(task.difficulty),
              ),
              const SizedBox(width: 8),
              _Tag(
                label: '${task.score} pts',
                color: Colors.blueGrey.shade200,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _difficultyColor(int difficulty) {
    if (difficulty >= 5) return const Color(0xFFFF9A9E);
    if (difficulty >= 3) return const Color(0xFFF1D16A);
    return const Color(0xFF9BE7A1);
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.black,
            ),
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  const _ActionButtons({
    required this.onDecline,
    required this.loading,
    this.onAccept,
    this.deleteOnly = false,
  });

  final VoidCallback? onAccept;
  final VoidCallback onDecline;
  final bool loading;
  final bool deleteOnly;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: deleteOnly
            ? [
                _ActionButton(
                  label: 'REMOVE',
                  gradientColors: const [Color(0xFFFC5B6B), Color(0xFFF89052)],
                  onPressed: loading ? null : onDecline,
                ),
              ]
            : [
                _ActionButton(
                  label: 'DECLINE',
                  gradientColors: const [Color(0xFFFC5B6B), Color(0xFFF89052)],
                  onPressed: loading ? null : onDecline,
                ),
                _ActionButton(
                  label: 'ACCEPT',
                  gradientColors: const [Color(0xFF75E966), Color(0xFFC7EF75)],
                  onPressed: loading ? null : onAccept,
                ),
              ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.gradientColors,
    required this.onPressed,
  });

  final String label;
  final List<Color> gradientColors;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            elevation: 8,
            shadowColor: Colors.black.withOpacity(0.3),
          ),
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: gradientColors,
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Container(
              alignment: Alignment.center,
              constraints: const BoxConstraints(minHeight: 50.0),
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
