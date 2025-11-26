// lib/shared/widgets/questions_bottom_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:skill_up/shared/widgets/likert_circle.dart';

class QuestionsBottomSheet extends StatefulWidget {
  const QuestionsBottomSheet({
    super.key,
    this.initialAnswers = const <int, int>{},
  });

  /// Risposte già salvate (es. {1:3, 2:0, ...})
  final Map<int, int> initialAnswers;

  @override
  State<QuestionsBottomSheet> createState() => _QuestionsBottomSheetState();
}

class _QuestionsBottomSheetState extends State<QuestionsBottomSheet> {
  final PageController _pageController = PageController(initialPage: 0);

  // 1..10 -> 0..4
  late Map<int, int> _answers;

  final List<String> _questions = const [
    'I usually have a clear idea of how I want to spend my day.',
    'I dedicate time each week to physical activity or movement.',
    'I feel satisfied with how I manage my free time.',
    'I’m able to keep focus when I’m working on something important.',
    'When trying something new, I prefer to learn gradually rather than all at once.',
    'I regularly review my goals and adjust them if needed.',
    'I feel I have a good balance between work / study and rest.',
    'I find it easy to disconnect from social media when I need to.',
    'I’m happy with how I take care of my body and mind.',
    'I’m confident in my ability to stick to a new habit.',
  ];

  @override
  void initState() {
    super.initState();
    _answers = Map<int, int>.from(widget.initialAnswers);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectAnswer(int questionIndex, int value) {
    setState(() {
      _answers[questionIndex] = value;
    });
  }

  void _goNextQuestion(int questionIndex) {
    if (!_answers.containsKey(questionIndex)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Please select an option before continuing.'),
            duration: Duration(milliseconds: 1300),
          ),
        );
      return;
    }

    if (questionIndex < 10) {
      // page index = questionIndex (1 -> pagina 1 [q2], ..., 9 -> pagina 9 [q10])
      _pageController.animateToPage(
        questionIndex,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      // ultima domanda → chiudo e ritorno le risposte
      Navigator.of(context).pop<Map<int, int>>(
        Map<int, int>.from(_answers),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 16,
                offset: Offset(0, -6),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
          child: Column(
            children: [
              // handle in alto
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 18),

              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  physics: const BouncingScrollPhysics(),
                  itemCount: 10, // solo domande
                  itemBuilder: (context, pageIndex) {
                    final questionIndex = pageIndex + 1; // 1..10
                    return _buildQuestionPage(textTheme, questionIndex);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuestionPage(TextTheme textTheme, int questionIndex) {
    final String questionText = _questions[questionIndex - 1];
    final int? selected = _answers[questionIndex];
    final bool isLast = questionIndex == 10;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'MORE ABOUT',
          textAlign: TextAlign.center,
          style: textTheme.displaySmall?.copyWith(
            fontFamily: 'FugazOne',
            fontSize: 44,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        Text(
          'YOU',
          textAlign: TextAlign.center,
          style: textTheme.displaySmall?.copyWith(
            fontFamily: 'FugazOne',
            fontSize: 44,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            children: [
              Text(
                questionText,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(5, (i) {
                  final bool isSelected = selected == i;
                  return LikertCircle(
                    filled: isSelected,
                    onTap: () => _selectAnswer(questionIndex, i),
                  );
                }),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Disagree',
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                    ),
                  ),
                  Text(
                    'Agree',
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 100),
        Row(
          children: [
            // contatore centrato meglio
            Expanded(
              child: Center(
                child: Text(
                  '$questionIndex/10',
                  style: textTheme.titleLarge?.copyWith(
                    fontFamily: 'FugazOne',
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
            GestureDetector(
              onTap: () => _goNextQuestion(questionIndex),
              child: Container(
                height: 72,
                width: 220,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.20),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 26),
                child: Row(
                  children: [
                    Text(
                      isLast ? 'FINISH' : 'NEXT',
                      style: textTheme.titleLarge?.copyWith(
                        fontFamily: 'FugazOne',
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        fontStyle: FontStyle.italic,
                        color: Colors.black,
                      ),
                    ),
                    const Spacer(),
                    SvgPicture.asset(
                      'assets/icons/send_icon.svg',
                      width: 36,
                      height: 36,
                      colorFilter: const ColorFilter.mode(
                        Colors.black,
                        BlendMode.srcIn,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}