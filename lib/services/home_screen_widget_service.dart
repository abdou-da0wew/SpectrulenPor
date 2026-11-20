import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

/// Bridge between Flutter state and the native Android AppWidget RemoteViews.
class HomeScreenWidgetService {
  HomeScreenWidgetService._();
  static final HomeScreenWidgetService instance = HomeScreenWidgetService._();

  static const String androidProvider = 'SpectruLenPorWidgetProvider';

  Future<void> update({
    required String status,
    required String model,
  }) async {
    if (kIsWeb) return;
    try {
      await HomeWidget.saveWidgetData<String>('widget_status', status);
      await HomeWidget.saveWidgetData<String>('widget_model', model);
      await HomeWidget.saveWidgetData<String>(
        'widget_updated',
        DateTime.now().toLocal().toString(),
      );
      await HomeWidget.updateWidget(androidName: androidProvider);
    } catch (error) {
      debugPrint('[HomeWidget] update failed: $error');
    }
  }

  Future<bool> requestPin() async {
    if (kIsWeb) return false;
    try {
      final supported = await HomeWidget.isRequestPinWidgetSupported();
      if (supported != true) return false;
      await HomeWidget.requestPinWidget(androidName: androidProvider);
      return true;
    } catch (error) {
      debugPrint('[HomeWidget] request pin failed: $error');
      return false;
    }
  }
}
