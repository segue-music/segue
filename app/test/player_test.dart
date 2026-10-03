import 'package:flutter_test/flutter_test.dart';
import 'package:segue/player/player.dart';
import 'package:segue/segue/client.dart';
import 'package:segue/segue/protocol.dart';
import 'package:segue/subsonic/api.dart';
import 'package:segue/subsonic/models.dart';

import 'fakes.dart';

final api = SubsonicApi(
  Uri.parse('https://music.test'),
  const SubsonicCredentials(username: 'a', token: 't', salt: 's'),
);

const songs = [
  Song(id: 's1', title: 'One', duration: Duration(minutes: 3)),
  Song(id: 's2', title: 'Two', duration: Duration(minutes: 4)),
];

void main() {
  late FakeEngine engine;
  late PlayerController player;
  late List<PlayerState> reports;

  setUp(() {
    engine = FakeEngine();
    player = PlayerController(engine, api);
    reports = [];
    player.onReport = reports.add;
  });

  test('plays a queue from the server, and reports it once', () async {
    await player.playQueue(songs, index: 1);
    expect(engine.tracks.last.queryParameters['id'], 's2');
    expect(player.current?.title, 'Two');
    expect(reports.first.queue?.map((item) => item.id), ['s1', 's2']);
    expect(reports.first.status, PlaybackStatus.playing);

    await player.toggle();
    expect(reports.last.status, PlaybackStatus.paused);
    expect(reports.last.queue, isNull, reason: 'the queue goes only when it changes');
    expect(player.report(full: true).queue, hasLength(2));
  });

  test('a seek is reported, though the engine says nothing', () async {
    await player.playQueue(songs);
    await player.seek(const Duration(seconds: 42));
    expect(reports.last.positionMs, greaterThanOrEqualTo(42000));
  });

  test('obeys commands, and refuses a track that is not there', () async {
    await player.playQueue(songs);
    await player.obey(const Command(CommandAction.next));
    expect(player.index, 1);
    await expectLater(player.obey(const Command(CommandAction.next)), throwsA(isA<CommandFailed>()));
    await player.obey(const Command.setVolume(30));
    expect(player.volume, 30);
    await player.obey(const Command(CommandAction.stop));
    expect(player.status, PlaybackStatus.stopped);
  });

  test('setQueue skips items without an id and keeps the current track current', () async {
    await player.obey(
      const Command.setQueue(
        queue: [
          QueueItem(title: 'Untranslatable'),
          QueueItem(id: 's1', title: 'One'),
          QueueItem(id: 's2', title: 'Two'),
        ],
        index: 2,
        positionMs: 5000,
        play: false,
      ),
    );
    expect(player.queue.map((song) => song.id), ['s1', 's2']);
    expect(player.current?.title, 'Two');
    expect(player.position, const Duration(seconds: 5));
    expect(player.playing, isFalse);
  });
}
