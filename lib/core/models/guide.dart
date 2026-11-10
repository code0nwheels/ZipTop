import 'json.dart';

/// `GET api/v2/guide`
class Guide {
  const Guide({
    this.windowStart,
    this.windowHours,
    this.horizonDays,
    this.categories = const [],
    this.channels = const [],
  });

  factory Guide.fromJson(Json json) {
    final window = asJson(json['window']);
    return Guide(
      windowStart: asTime(window?['start']),
      windowHours: asInt(window?['hours']),
      horizonDays: asInt(window?['horizon_days']),
      categories: asList(json['categories'], GuideCategory.tryParse),
      channels: asList(json['channels'], GuideChannel.tryParse),
    );
  }

  final DateTime? windowStart;
  final int? windowHours;
  final int? horizonDays;
  final List<GuideCategory> categories;
  final List<GuideChannel> channels;
}

class GuideCategory {
  const GuideCategory({
    required this.id,
    this.kind,
    this.name = '',
    this.icon,
    this.hidden = false,
    this.streamIds = const [],
  });

  static GuideCategory? tryParse(Json json) {
    final id = asString(json['id']);
    if (id == null) return null;
    return GuideCategory(
      id: id,
      kind: asString(json['kind']),
      name: asString(json['name']) ?? '',
      icon: asString(json['icon']),
      hidden: asBool(json['hidden']) ?? false,
      streamIds: asStringList(json['stream_ids']),
    );
  }

  final String id;
  final String? kind;
  final String name;
  final String? icon;
  final bool hidden;
  final List<String> streamIds;
}

class GuideChannel {
  const GuideChannel({
    required this.id,
    this.number,
    this.name = '',
    this.type,
    this.categoryId,
    this.programmes = const [],
  });

  static GuideChannel? tryParse(Json json) {
    final id = asString(json['id']);
    if (id == null) return null;
    return GuideChannel(
      id: id,
      number: asInt(json['number']),
      name: asString(json['name']) ?? '',
      type: asString(json['type']),
      categoryId: asString(json['category_id']),
      programmes: asList(json['programmes'], Programme.tryParse),
    );
  }

  final String id;
  final int? number;
  final String name;
  final String? type;
  final String? categoryId;
  final List<Programme> programmes;
}

class Programme {
  const Programme({
    required this.title,
    this.description,
    required this.start,
    required this.stop,
    this.isOnNow = false,
  });

  static Programme? tryParse(Json json) {
    final start = asTime(json['start']);
    final stop = asTime(json['stop']);
    if (start == null || stop == null) return null;
    return Programme(
      title: asString(json['title']) ?? '',
      description: asString(json['description']),
      start: start,
      stop: stop,
      isOnNow: asBool(json['is_on_now']) ?? false,
    );
  }

  final String title;
  final String? description;
  final DateTime start;
  final DateTime stop;

  /// The server's view of "on now"; used when a feed's clock offsets are broken.
  final bool isOnNow;

  bool airsAt(DateTime when) => !when.isBefore(start) && when.isBefore(stop);
}
