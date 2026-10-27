import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

/// JSON cannot carry a number that is not a number (such as 0 ÷ 0) or is
/// infinite. Every message the app sends goes through [operatorEncodeJson],
/// which sends such a number empty and lists where it was, and any other value
/// JSON cannot carry (such as an app's own enum) as its text, so no single
/// value stops the whole message.
void main() {
  test('each unreadable number is sent empty and listed with where it was', () {
    final message = <String, Object?>{
      'ui': <String, Object?>{
        'elements': <Object?>[
          <String, Object?>{
            'role': 'button',
            'label': 'Save',
            'bounds': <String, Object?>{'x': double.nan, 'y': 4.0},
          },
        ],
      },
      'state': <Object?>[
        <String, Object?>{
          'widget': 'ScaleTransition',
          'value': double.infinity,
        },
        <String, Object?>{
          'values': <Object?>[1, double.negativeInfinity],
        },
      ],
    };

    final sent = jsonDecode(operatorEncodeJson(message)) as Map;

    final element = ((sent['ui'] as Map)['elements'] as List).single as Map;
    expect(element['bounds'], <String, Object?>{'x': null, 'y': 4.0});
    expect(((sent['state'] as List).first as Map)['value'], isNull);
    expect(((sent['state'] as List).last as Map)['values'], <Object?>[1, null]);
    final unreadable = sent['unreadableValues'] as Map;
    expect(unreadable['note'], contains('not numbers'));
    expect(unreadable['values'], <Object?>[
      <String, Object?>{
        'path': r'$.ui.elements[0].bounds.x',
        'item': 'button "Save"',
        'value': 'NaN',
      },
      <String, Object?>{
        'path': r'$.state[0].value',
        'item': 'ScaleTransition',
        'value': 'Infinity',
      },
      <String, Object?>{'path': r'$.state[1].values[1]', 'value': '-Infinity'},
    ]);
    expect(unreadable.containsKey('more'), isFalse);
  });

  test('the item is what names itself, never a bare category inside it', () {
    final message = <String, Object?>{
      'ui': <String, Object?>{
        'elements': <Object?>[
          <String, Object?>{
            'role': 'list',
            'label': 'Tasks',
            'scrollOwner': <String, Object?>{
              'kind': 'element',
              'maxOffset': <String, Object?>{'y': double.infinity},
            },
          },
        ],
      },
      'state': <Object?>[
        <String, Object?>{
          'name': 'FlutterWidgetTree',
          'value': <String, Object?>{
            'listenables': <Object?>[
              <String, Object?>{
                'widget': 'ValueListenableBuilder<double>',
                'value': double.nan,
              },
            ],
          },
        },
        <String, Object?>{
          'name': 'TasksState',
          'value': <String, Object?>{'type': 'loaded', 'progress': double.nan},
        },
      ],
      'storage': <String, Object?>{
        'entries': <Object?>[
          <String, Object?>{'key': 'ratio', 'value': double.nan},
        ],
      },
    };

    final unreadable =
        (operatorReadableJson(message) as Map)['unreadableValues'] as Map;

    expect(
      (unreadable['values'] as List).map((value) => (value as Map)['item']),
      <Object?>[
        'list "Tasks"',
        'ValueListenableBuilder<double>',
        '"TasksState"',
        '"ratio"',
      ],
    );
  });

  test('a message without one comes back as it was', () {
    final message = <String, Object?>{
      'x': 1.5,
      'items': <Object?>[1, 'a', null, true],
    };

    expect(identical(operatorReadableJson(message), message), isTrue);
    expect(jsonDecode(operatorEncodeJson(message)), message);
  });

  test('only the parts holding one are copied', () {
    final clean = <String, double>{'x': 1, 'y': 2};
    final message = <String, Object?>{
      'clean': clean,
      'dirty': <String, Object?>{'x': double.nan},
    };

    final sent = operatorReadableJson(message) as Map;

    expect(identical(sent['clean'], clean), isTrue);
    expect(sent['dirty'], <String, Object?>{'x': null});
    expect(message['dirty'], <String, Object?>{'x': isNaN});
  });

  test('a message that already lists some keeps them and adds the new', () {
    final once =
        operatorReadableJson(<String, Object?>{'a': double.nan}) as JsonMap;
    final twice =
        operatorReadableJson(<String, Object?>{...once, 'b': double.infinity})
            as Map;

    expect(
      ((twice['unreadableValues'] as Map)['values'] as List).map(
        (value) => (value as Map)['path'],
      ),
      <Object?>[r'$.a', r'$.b'],
    );
  });

  test('the list names twenty and counts the rest', () {
    final message = <String, Object?>{
      'values': List<Object?>.filled(25, double.nan),
    };

    final sent = operatorReadableJson(message) as Map;

    expect(sent['values'], List<Object?>.filled(25, null));
    final unreadable = sent['unreadableValues'] as Map;
    expect(unreadable['values'], hasLength(20));
    expect(unreadable['more'], 5);
  });

  test('a message that already counts more keeps counting them', () {
    final once =
        operatorReadableJson(<String, Object?>{
              'values': List<Object?>.filled(25, double.nan),
            })
            as JsonMap;
    final twice =
        operatorReadableJson(<String, Object?>{...once, 'b': double.infinity})
            as Map;

    final unreadable = twice['unreadableValues'] as Map;
    expect(unreadable['values'], hasLength(20));
    expect(unreadable['more'], 6);
  });

  test('a message that is not an object sends them empty, unlisted', () {
    expect(
      jsonDecode(
        operatorEncodeJson(<Object?>[
          1.5,
          double.nan,
          <String, Object?>{'x': double.infinity},
        ]),
      ),
      <Object?>[
        1.5,
        null,
        <String, Object?>{'x': null},
      ],
    );
  });

  test('any other value JSON cannot carry is sent as its text', () {
    final sent =
        jsonDecode(
              operatorEncodeJson(<String, Object?>{
                'filter': _TaskType.closed,
                'plain': _Plain(),
                'at': DateTime.utc(2026, 9, 30),
                'byNumber': <int, String>{1: 'one'},
                'model': _Model(),
                'unusableModel': _UnusableModel(),
                'numberKeyedModel': _NumberKeyedModel(),
                'failingModel': _FailingModel(),
              }),
            )
            as Map;

    expect(sent['filter'], '_TaskType.closed');
    expect(sent['plain'], "Instance of '_Plain'");
    expect(sent['at'], '2026-09-30T00:00:00.000Z');
    expect(sent['byNumber'], <String, Object?>{'1': 'one'});
    // A value with its own JSON is sent as that JSON, as before; one whose
    // toJson() gives something JSON cannot carry is sent as its text.
    expect(sent['model'], <String, Object?>{'id': 7});
    expect(sent['unusableModel'], "Instance of '_UnusableModel'");
    expect(sent['numberKeyedModel'], <String, Object?>{'1': 'one'});
    expect(sent['failingModel'], "Instance of '_FailingModel'");
  });
}

enum _TaskType { closed }

class _Plain {}

class _Model {
  Map<String, Object?> toJson() => <String, Object?>{'id': 7};
}

class _UnusableModel {
  Object toJson() => _TaskType.closed;
}

class _NumberKeyedModel {
  Map<int, String> toJson() => <int, String>{1: 'one'};
}

class _FailingModel {
  Object toJson() => throw StateError('no JSON for this value');
}
