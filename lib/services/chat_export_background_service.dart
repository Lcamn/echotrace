import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/chat_session.dart';
import '../models/message.dart';
import '../services/chat_export_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';

class ChatExportBackgroundService {
  static const String messageProgress = 'progress';
  static const String messageDone = 'done';
  static const String messageError = 'error';

  static Future<Isolate> startExport({
    required SendPort sendPort,
    required String dbPath,
    required String? manualWxid,
    required List<Map<String, dynamic>> sessions,
    required String format,
    required String exportFolder,
    required int startTimestamp,
    required int endTimestamp,
  }) {
    final task = <String, dynamic>{
      'sendPort': sendPort,
      'dbPath': dbPath,
      'manualWxid': manualWxid,
      'sessions': sessions,
      'format': format,
      'exportFolder': exportFolder,
      'startTimestamp': startTimestamp,
      'endTimestamp': endTimestamp,
    };
    return Isolate.spawn(_runExport, task);
  }

  static Future<void> _runExport(Map<String, dynamic> task) async {
    if (!logger.isInIsolateMode) {
      logger.enableIsolateMode();
    }

    final SendPort sendPort = task['sendPort'] as SendPort;
    final String dbPath = task['dbPath'] as String;
    final String? manualWxid = task['manualWxid'] as String?;
    final List sessionsRaw =
        (task['sessions'] as List?) ?? const <Map<String, dynamic>>[];
    final String format = task['format'] as String;
    final String exportFolder = task['exportFolder'] as String;
    final int startTimestamp = task['startTimestamp'] as int;
    final int endTimestamp = task['endTimestamp'] as int;

    DatabaseService? databaseService;
    try {
      sqfliteFfiInit();
      databaseService = DatabaseService();
      if (manualWxid != null && manualWxid.isNotEmpty) {
        databaseService.setManualWxid(manualWxid);
      }
      await databaseService.initialize(factory: databaseFactoryFfi);
      await databaseService.connectDecryptedDatabase(
        dbPath,
        factory: databaseFactoryFfi,
      );

      final exportService = ChatExportService(databaseService);
      final sessions = sessionsRaw
          .map(
            (item) => (item as Map).map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          )
          .toList();

      int totalMessagesProcessed = 0;
      int displayExportedCount = 0;
      int successCount = 0;
      int failedCount = 0;
      final failedSessions = <String>[];
      int lastProgressSentMs = 0;

      for (int i = 0; i < sessions.length; i++) {
        final sessionMap = sessions[i];
        final displayNameRaw = sessionMap['displayName'] as String?;
        final session = ChatSession.fromMap(sessionMap);
        session.displayName =
            displayNameRaw != null && displayNameRaw.isNotEmpty
                ? displayNameRaw
                : null;

        sendPort.send({
          'type': messageProgress,
          'currentIndex': i,
          'totalSessions': sessions.length,
          'sessionName': session.displayName ?? session.username,
          'scannedCount': 0,
          'exportedCount': totalMessagesProcessed,
          'totalMessagesProcessed': totalMessagesProcessed,
          'successCount': successCount,
          'failedCount': failedCount,
          'isScanning': true,
          'stage': '正在扫描消息...',
        });

        List<Message> messages = [];
        void reportProgress(int count) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastProgressSentMs < 120) return;
          lastProgressSentMs = now;
          sendPort.send({
            'type': messageProgress,
            'currentIndex': i,
            'totalSessions': sessions.length,
            'sessionName': session.displayName ?? session.username,
            'scannedCount': count,
            'exportedCount': totalMessagesProcessed,
            'totalMessagesProcessed': totalMessagesProcessed,
            'successCount': successCount,
            'failedCount': failedCount,
            'isScanning': true,
            'stage': '正在扫描消息...',
          });
        }

        try {
          messages = await databaseService.getMessagesByDate(
            session.username,
            startTimestamp,
            endTimestamp,
            onProgress: reportProgress,
          );
        } catch (e) {
          failedCount++;
          failedSessions.add(
            '${session.displayName ?? session.username} ($e)',
          );
          sendPort.send({
            'type': messageProgress,
            'currentIndex': i,
            'totalSessions': sessions.length,
            'sessionName': session.displayName ?? session.username,
            'scannedCount': 0,
            'totalMessagesProcessed': totalMessagesProcessed,
            'successCount': successCount,
            'failedCount': failedCount,
            'isScanning': false,
          });
          continue;
        }

        sendPort.send({
          'type': messageProgress,
          'currentIndex': i,
          'totalSessions': sessions.length,
          'sessionName': session.displayName ?? session.username,
          'scannedCount': messages.length,
          'exportedCount': totalMessagesProcessed,
          'totalMessagesProcessed': totalMessagesProcessed,
          'successCount': successCount,
          'failedCount': failedCount,
          'isScanning': false,
          'stage': '正在生成导出文件...',
        });

        if (messages.isEmpty) {
          failedCount++;
          failedSessions.add(
            '${session.displayName ?? session.username} (无消息)',
          );
          continue;
        }

        final displayName = session.displayName ?? session.username;
        final sanitizedName =
            displayName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filePath =
            '$exportFolder${Platform.pathSeparator}${sanitizedName}_$timestamp.$format';

        bool success = false;
        displayExportedCount = totalMessagesProcessed;
        switch (format) {
          case 'json':
            success = await exportService.exportToJson(
              session,
              messages.reversed.toList(),
              filePath: filePath,
              streaming: true,
              onProgress: (count, total) {
                displayExportedCount = totalMessagesProcessed + count;
                sendPort.send({
                  'type': messageProgress,
                  'currentIndex': i,
                  'totalSessions': sessions.length,
                  'sessionName': session.displayName ?? session.username,
                  'scannedCount': messages.length,
                  'exportedCount': displayExportedCount,
                  'totalMessagesProcessed': totalMessagesProcessed,
                  'successCount': successCount,
                  'failedCount': failedCount,
                  'isScanning': false,
                  'stage': '正在写入导出文件...',
                });
              },
            );
            break;
          case 'html':
            success = await exportService.exportToHtml(
              session,
              messages.reversed.toList(),
              filePath: filePath,
              onProgress: (count, total) {
                displayExportedCount = totalMessagesProcessed + count;
                sendPort.send({
                  'type': messageProgress,
                  'currentIndex': i,
                  'totalSessions': sessions.length,
                  'sessionName': session.displayName ?? session.username,
                  'scannedCount': messages.length,
                  'exportedCount': displayExportedCount,
                  'totalMessagesProcessed': totalMessagesProcessed,
                  'successCount': successCount,
                  'failedCount': failedCount,
                  'isScanning': false,
                  'stage': '正在生成导出文件...',
                });
              },
            );
            break;
          case 'xlsx':
            success = await exportService.exportToExcel(
              session,
              messages.reversed.toList(),
              filePath: filePath,
              onProgress: (count, total) {
                displayExportedCount = totalMessagesProcessed + count;
                sendPort.send({
                  'type': messageProgress,
                  'currentIndex': i,
                  'totalSessions': sessions.length,
                  'sessionName': session.displayName ?? session.username,
                  'scannedCount': messages.length,
                  'exportedCount': displayExportedCount,
                  'totalMessagesProcessed': totalMessagesProcessed,
                  'successCount': successCount,
                  'failedCount': failedCount,
                  'isScanning': false,
                  'stage': '正在生成表格...',
                });
              },
            );
            break;
          case 'sql':
            success = await exportService.exportToPostgreSQL(
              session,
              messages.reversed.toList(),
              filePath: filePath,
              streaming: true,
              onProgress: (count, total) {
                displayExportedCount = totalMessagesProcessed + count;
                sendPort.send({
                  'type': messageProgress,
                  'currentIndex': i,
                  'totalSessions': sessions.length,
                  'sessionName': session.displayName ?? session.username,
                  'scannedCount': messages.length,
                  'exportedCount': displayExportedCount,
                  'totalMessagesProcessed': totalMessagesProcessed,
                  'successCount': successCount,
                  'failedCount': failedCount,
                  'isScanning': false,
                  'stage': '正在写入导出文件...',
                });
              },
            );
            break;
        }

        if (success) {
          successCount++;
          totalMessagesProcessed += messages.length;
          displayExportedCount = totalMessagesProcessed;
        } else {
          failedCount++;
          failedSessions.add(
            '${session.displayName ?? session.username} (导出失败)',
          );
        }

        sendPort.send({
          'type': messageProgress,
          'currentIndex': i,
          'totalSessions': sessions.length,
          'sessionName': session.displayName ?? session.username,
          'scannedCount': messages.length,
          'exportedCount': displayExportedCount,
          'totalMessagesProcessed': totalMessagesProcessed,
          'successCount': successCount,
          'failedCount': failedCount,
          'isScanning': false,
          'stage': '正在写入磁盘...',
        });
      }

      sendPort.send({
        'type': messageDone,
        'successCount': successCount,
        'failedCount': failedCount,
        'totalMessagesProcessed': totalMessagesProcessed,
        'failedSessions': failedSessions,
      });
    } catch (e) {
      sendPort.send({'type': messageError, 'error': e.toString()});
    } finally {
      try {
        await databaseService?.close();
      } catch (_) {}
    }
  }
}
