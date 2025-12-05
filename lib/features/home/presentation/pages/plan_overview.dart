import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:skill_up/features/home/data/task_api.dart';
import 'package:skill_up/features/home/domain/medal_utils.dart';
import 'package:flutter/services.dart';
import 'package:skill_up/shared/widgets/gradient_icon_button.dart';

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

    final activeWeekdays = _tasksByDay.keys.map((d) => d.weekday).toSet();

    int? totalWeeks;
    if (start != null && end != null) {
      final days = end.difference(start).inDays + 1;
      totalWeeks = ((days + 6) ~/ 7);
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            const _GradientBackground(),

            // 👇 CONTENUTO SCORREVOLE
            SafeArea(
              child: Column(
                children: [
                  _OverviewHeaderSection(
                    planId: widget.args.planId,
                    activeWeekdays: activeWeekdays,
                    totalWeeks: totalWeeks,
                    totalTasks: tasksCount,
                    timeSpan: span,
                    prompt: widget.args.prompt,
                    onBack: widget.args.deleteOnly
                    // 👇 se arrivo dal profilo: solo pop, NON eliminare
                        ? () {
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                    }
                    // 👇 se arrivo dal flow di generazione: comportati come DECLINE
                        : _handleDecline,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 18,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                  color: Colors.redAccent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 👇 PULSANTI FISSI, IN BASSO, SOPRA IL CONTENUTO
            Positioned(
              bottom: 65,   // ⬆️ - prima era 24, ora li alziamo
              left: 0,
              right: 0,
              child: _ActionButtons(
                loading: _processing,
                onAccept: widget.args.deleteOnly ? null : _handleAccept,
                onDecline: _handleDecline,
                deleteOnly: widget.args.deleteOnly,
              ),
            ),
          ],
        ),
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
              Color(0xFFFFB3A7), // rosa
              Color(0xFFFFD5C2), // pesca chiaro (smooth)
              Color(0xFFFFECCA), // crema (transizione dolce)
              Color(0xFFFFCF71), // giallo originale
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
    return Transform.translate(
      offset: const Offset(0, 0), // 👈 per incollarlo al bordo sinistro
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 70,
          height: 56,
          decoration: const BoxDecoration(
            color: Color(0xFFB3B3B3),
            borderRadius: BorderRadius.horizontal(
              right: Radius.circular(28),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,       // 👈 identico al secondo pill
                blurRadius: 8,
                offset: Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.only(left: 14),
          alignment: Alignment.centerLeft,
          child: Image.asset(
            'assets/icons/back.png',
            width: 32,
            height: 32,
            fit: BoxFit.contain,
          ),
        ),
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
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: deleteOnly
            ? [
          GradientTextButton(
            label: 'REMOVE',
            onTap: loading ? () {} : onDecline,
            width: 190,
            height: 64,
          ),
        ]
            : [
          GradientTextButton(
            label: 'REPLAN',
            onTap: loading ? () {} : onDecline,
            width: 190,
            height: 64,
          ),
          const SizedBox(width: 20),
          GradientTextButton(
            label: 'ACCEPT',
            onTap: loading ? () {} : (onAccept ?? () {}),
            width: 190,
            height: 64,
          ),
        ],
      ),
    );
  }
}

class GradientTextButton extends StatelessWidget {
  const GradientTextButton({
    super.key,
    required this.onTap,
    required this.label,
    this.width = 140,
    this.height = 56,
  });

  final VoidCallback onTap;
  final String label;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 10,
              offset: Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 1.1,
          ),
        ),
      ),
    );
  }
}


class _WeekdayRow extends StatelessWidget {
  const _WeekdayRow();

  @override
  Widget build(BuildContext context) {
    const labels = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

    return Row(
      mainAxisAlignment: MainAxisAlignment.center, // CENTRATO
      children: labels
          .map(
            (l) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            l,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      )
          .toList(),
    );
  }
}

class _WeekdayDots extends StatelessWidget {
  const _WeekdayDots({required this.activeWeekdays});

  final Set<int> activeWeekdays;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center, // CENTRA TUTTA LA ROW
      children: List.generate(7, (index) {
        final weekday = index + 1;
        final isActive = activeWeekdays.contains(weekday);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6), // SPAZIO COSTANTE
          child: _DayCircle(active: isActive),
        );
      }),
    );
  }
}

class _DayCircle extends StatelessWidget {
  const _DayCircle({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? const Color(0xFF72E07B) : Colors.white,
        border: Border.all(
          color: Colors.black,
          width: 2,
        ),
      ),
    );
  }
}

class _OverviewHeaderSection extends StatelessWidget {
  const _OverviewHeaderSection({
    required this.planId,
    required this.activeWeekdays,
    required this.totalWeeks,
    required this.totalTasks,
    required this.timeSpan,
    required this.onBack,
    this.prompt,
  });

  final int planId;
  final Set<int> activeWeekdays;
  final int? totalWeeks;
  final int totalTasks;
  final String timeSpan;
  final String? prompt;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final weeksLabel = totalWeeks == null
        ? 'Total duration: —'
        : 'Total duration: $totalWeeks ${totalWeeks == 1 ? 'week' : 'weeks'}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(0, 24, 24, 26),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFFFFD5C2), // pesca morbido
            Color(0xFFFFB3A7), // rosa in alto
          ],
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
        ),
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(40),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // FRECCIA + TITOLO
          Padding(
            padding: const EdgeInsets.only(left: 0, right: 0, bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _BackPill(onTap: onBack),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'PLAN OVERVIEW',
                    maxLines: 1,
                    textAlign: TextAlign.left,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'FredokaOne',
                      fontSize: 35,
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // GIORNI + PALLINI (allineati uno sopra l'altro)
          _WeekdayStrip(activeWeekdays: activeWeekdays),
          const SizedBox(height: 12), // spazio prima di "Total duration"

          // DURATA
          Text(
            weeksLabel,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.black,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),

          Text(
            timeSpan,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.black87,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 10),

          // GOAL
          Text(
            'Goal',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.black,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            (prompt != null && prompt!.trim().isNotEmpty) ? prompt! : '—',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

/// Giorno + pallino nello stesso blocco, centrati
class _WeekdayStrip extends StatelessWidget {
  const _WeekdayStrip({required this.activeWeekdays});

  final Set<int> activeWeekdays; // 1 = Monday ... 7 = Sunday

  @override
  Widget build(BuildContext context) {
    const labels = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(7, (index) {
        final weekday = index + 1;
        final isActive = activeWeekdays.contains(weekday);
        final label = labels[index];

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              _DayCircle(active: isActive),
            ],
          ),
        );
      }),
    );
  }
}
