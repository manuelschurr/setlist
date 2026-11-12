import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final db = sqlite3.openInMemory();
  final version = db.select('select sqlite_version() as v').first['v'];
  runApp(MaterialApp(home: Scaffold(body: Center(child: Text('sqlite $version')))));
}
