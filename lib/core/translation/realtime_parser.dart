import 'translation_models.dart';

abstract interface class RealtimeParser {
  List<TranslationEvent> accept(Map<String, dynamic> event);
  List<TranslationEvent> interrupt();
}
