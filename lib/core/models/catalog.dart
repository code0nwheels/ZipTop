import 'json.dart';

/// Ids of the server-generated rows. Channel category ids are opaque; never build them.
abstract final class CategoryIds {
  static const popular = 'system:popular';
  static const continueWatching = 'system:continue_watching';
  static const favorites = 'system:favorites';
  static const all = 'system:all';
  static const kindSystem = 'system';
}

/// `GET api/v2/catalog`
class Catalog {
  const Catalog({
    this.apiVersion,
    this.accessMode,
    this.canViewCounts = false,
    this.planStatus,
    this.favoriteIds = const [],
    this.streams = const [],
    this.categories = const [],
  });

  factory Catalog.fromJson(Json json) {
    final viewer = asJson(json['viewer']);
    final plans = asJson(viewer?['plan_status']);
    return Catalog(
      apiVersion: asInt(json['api_version']),
      accessMode: asString(viewer?['access_mode']),
      canViewCounts: asBool(viewer?['can_view_counts']) ?? false,
      planStatus: plans == null ? null : PlanStatus.fromJson(plans),
      favoriteIds: asStringList(json['favorite_ids']),
      streams: asList(json['streams'], Channel.tryParse),
      categories: asList(json['categories'], Category.tryParse),
    );
  }

  final int? apiVersion;
  final String? accessMode;
  final bool canViewCounts;

  /// The viewer's season plans; only sent for a `plans` account.
  final PlanStatus? planStatus;
  final List<String> favoriteIds;
  final List<Channel> streams;
  final List<Category> categories;
}

/// `viewer.plan_status` in the catalogue: the season plans running now, the
/// one that ended last and the next one booked.
class PlanStatus {
  const PlanStatus({this.activePlans = const [], this.lastEnded, this.nextPlan});

  factory PlanStatus.fromJson(Json json) {
    final last = asJson(json['last_ended']);
    final next = asJson(json['next_plan']);
    return PlanStatus(
      activePlans: asList(json['active_plans'], PlanPeriod.tryParse),
      lastEnded: last == null ? null : PlanPeriod.tryParse(last),
      nextPlan: next == null ? null : PlanPeriod.tryParse(next),
    );
  }

  final List<PlanPeriod> activePlans;
  final PlanPeriod? lastEnded;
  final PlanPeriod? nextPlan;
}

/// One season plan and when it runs.
class PlanPeriod {
  const PlanPeriod({required this.name, this.startsAt, this.endsAt});

  static PlanPeriod? tryParse(Json json) {
    final name = asString(json['name']);
    if (name == null || name.isEmpty) return null;
    return PlanPeriod(
      name: name,
      startsAt: asString(json['starts_at']),
      endsAt: asString(json['ends_at']),
    );
  }

  final String name;
  final String? startsAt;
  final String? endsAt;
}

/// One channel (`streams[]` in the catalogue).
class Channel {
  const Channel({
    required this.id,
    this.number,
    this.name = '',
    this.type,
    this.categoryId,
    this.group,
    this.subgroup,
    this.nowPlaying,
  });

  static Channel? tryParse(Json json) {
    final id = asString(json['id']);
    if (id == null) return null;
    final now = asJson(json['now_playing']);
    return Channel(
      id: id,
      number: asInt(json['number']),
      name: asString(json['name']) ?? '',
      type: asString(json['type']),
      categoryId: asString(json['category_id']),
      group: asString(json['group']),
      subgroup: asString(json['subgroup']),
      nowPlaying: now == null ? null : NowPlaying.fromJson(now),
    );
  }

  static const typeIptv = 'iptv';
  static const type247 = '24_7';
  static const typeUserRtmp = 'user_rtmp';
  static const typeRtmp = 'rtmp';

  final String id;
  final int? number;
  final String name;
  final String? type;
  final String? categoryId;
  final String? group;
  final String? subgroup;
  final NowPlaying? nowPlaying;

  /// Only IPTV channels take the start-then-play path.
  bool get isIptv => type == typeIptv;

  /// 24/7 channels and people's own broadcasts never need starting.
  bool get isAlwaysOn => type == type247 || type == typeUserRtmp;
}

class NowPlaying {
  const NowPlaying({this.title, this.description, this.start, this.stop});

  factory NowPlaying.fromJson(Json json) => NowPlaying(
        title: asString(json['title']),
        description: asString(json['description']),
        start: asTime(json['start']),
        stop: asTime(json['stop']),
      );

  final String? title;
  final String? description;
  final DateTime? start;
  final DateTime? stop;
}

class Category {
  const Category({
    required this.id,
    this.kind,
    this.name = '',
    this.rawName,
    this.icon,
    this.section,
    this.isPriority = false,
    this.hidden = false,
    this.streamIds = const [],
    this.feeds = const [],
    this.subgroups = const [],
  });

  static Category? tryParse(Json json) {
    final id = asString(json['id']);
    if (id == null) return null;
    return Category(
      id: id,
      kind: asString(json['kind']),
      name: asString(json['name']) ?? '',
      rawName: asString(json['raw_name']),
      icon: asString(json['icon']),
      section: asString(json['section']),
      isPriority: asBool(json['is_priority']) ?? false,
      hidden: asBool(json['hidden']) ?? false,
      streamIds: asStringList(json['stream_ids']),
      feeds: asList(json['feeds'], Feed.tryParse),
      subgroups: asList(json['subgroups'], Subgroup.fromJson),
    );
  }

  final String id;
  final String? kind;
  final String name;
  final String? rawName;
  final String? icon;
  final String? section;
  final bool isPriority;
  final bool hidden;
  final List<String> streamIds;
  final List<Feed> feeds;
  final List<Subgroup> subgroups;

  bool get isSystem => kind == CategoryIds.kindSystem;

  Category withStreamIds(List<String> ids) => Category(
        id: id,
        kind: kind,
        name: name,
        rawName: rawName,
        icon: icon,
        section: section,
        isPriority: isPriority,
        hidden: hidden,
        streamIds: ids,
        feeds: feeds,
        subgroups: subgroups,
      );
}

/// One provider's cut of a multi-provider category.
class Feed {
  const Feed({
    required this.id,
    this.name,
    this.label,
    this.isPriority = false,
    this.streamIds = const [],
  });

  static Feed? tryParse(Json json) {
    final id = asString(json['id']);
    if (id == null) return null;
    return Feed(
      id: id,
      name: asString(json['name']),
      label: asString(json['label']),
      isPriority: asBool(json['is_priority']) ?? false,
      streamIds: asStringList(json['stream_ids']),
    );
  }

  final String id;
  final String? name;
  final String? label;
  final bool isPriority;
  final List<String> streamIds;
}

class Subgroup {
  const Subgroup({this.name, this.streamIds = const []});

  static Subgroup fromJson(Json json) => Subgroup(
        name: asString(json['name']),
        streamIds: asStringList(json['stream_ids']),
      );

  final String? name;
  final List<String> streamIds;
}

/// `GET api/v2/live`
class LiveState {
  const LiveState({
    this.capacityFull = false,
    this.states = const {},
    this.popularIds,
    this.viewerCounts,
  });

  factory LiveState.fromJson(Json json) => LiveState(
        capacityFull: asBool(json['capacity_full']) ?? false,
        states: asMapOf(json['states'], asString),
        popularIds:
            json['popular_ids'] is List ? asStringList(json['popular_ids']) : null,
        viewerCounts: json['viewer_counts'] is Map
            ? asMapOf(json['viewer_counts'], asInt)
            : null,
      );

  final bool capacityFull;

  /// running, paused, retrying, unavailable. Channels with no entry are stopped.
  final Map<String, String> states;
  final List<String>? popularIds;

  /// Only present for accounts allowed to see counts.
  final Map<String, int>? viewerCounts;
}

/// `PUT` / `DELETE api/v2/favorites/{id}`
class FavoritesResult {
  const FavoritesResult({this.streamId, this.isFavorite, this.favoriteIds = const []});

  factory FavoritesResult.fromJson(Json json) => FavoritesResult(
        streamId: asString(json['stream_id']),
        isFavorite: asBool(json['is_favorite']),
        favoriteIds: asStringList(json['favorite_ids']),
      );

  final String? streamId;
  final bool? isFavorite;
  final List<String> favoriteIds;
}

/// `GET` / `PUT api/v2/categories/preferences`
class CategoryPrefs {
  const CategoryPrefs({
    this.order = const [],
    this.hidden = const [],
    this.categories = const [],
  });

  factory CategoryPrefs.fromJson(Json json) => CategoryPrefs(
        order: asStringList(json['order']),
        hidden: asStringList(json['hidden']),
        categories: asList(json['categories'], CategoryPref.tryParse),
      );

  final List<String> order;
  final List<String> hidden;
  final List<CategoryPref> categories;
}

class CategoryPref {
  const CategoryPref({
    required this.id,
    this.kind,
    this.name = '',
    this.rawName,
    this.icon,
    this.section,
    this.hidden = false,
    this.reorderable = false,
    this.count = 0,
  });

  static CategoryPref? tryParse(Json json) {
    final id = asString(json['id']);
    if (id == null) return null;
    return CategoryPref(
      id: id,
      kind: asString(json['kind']),
      name: asString(json['name']) ?? '',
      rawName: asString(json['raw_name']),
      icon: asString(json['icon']),
      section: asString(json['section']),
      hidden: asBool(json['hidden']) ?? false,
      reorderable: asBool(json['reorderable']) ?? false,
      count: asInt(json['count']) ?? 0,
    );
  }

  final String id;
  final String? kind;
  final String name;
  final String? rawName;
  final String? icon;
  final String? section;
  final bool hidden;
  final bool reorderable;
  final int count;
}

/// PUT body. Send only what changes: `hide` / `show` for toggles, the full
/// `order` (hidden ones included) on save.
class CategoryPrefsUpdate {
  const CategoryPrefsUpdate({this.order, this.hide, this.show});

  final List<String>? order;
  final List<String>? hide;
  final List<String>? show;

  Json toJson() => {
        if (order != null) 'order': order,
        if (hide != null) 'hide': hide,
        if (show != null) 'show': show,
      };
}
