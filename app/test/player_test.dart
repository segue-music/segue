import 'package:flutter_test/flutter_test.dart';
import 'package:segue/player/player.dart';
import 'package:segue/segue/client.dart';
import 'package:segue/segue/protocol.dart';
import 'package:segue/server/models.dart';
import 'package:segue/subsonic/api.dart';

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

  test('previous goes back to the start of the track, and to the previous one in its first seconds', () async {
    await player.playQueue(songs, index: 1, position: const Duration(seconds: 40));
    await player.previous();
    expect(player.index, 1);
    expect(player.position.inSeconds, 0);
    await player.previous();
    expect(player.index, 0);
    await player.seek(const Duration(seconds: 1));
    await player.previous(); // the first track: back to its start, never an error
    expect(player.index, 0);
    expect(player.position.inSeconds, 0);
  });

  test('a jump plays the track at that place in the queue from its start, even paused', () async {
    const three = [...songs, Song(id: 's3', title: 'Three')];
    await player.playQueue(three, position: const Duration(seconds: 30), play: false);
    await player.jump(2);
    expect(player.current?.id, 's3');
    expect(player.playing, isTrue);
    expect(player.position.inSeconds, 0);
    expect(reports.last.index, 2);
    expect(reports.last.status, PlaybackStatus.playing);

    await player.seek(const Duration(seconds: 30));
    await player.jump(2);
    expect(player.index, 2);
    expect(player.position.inSeconds, 0, reason: 'the current track starts over');

    await player.obey(const Command.jump(0));
    expect(player.current?.id, 's1');
    await expectLater(player.obey(const Command.jump(3)), throwsA(isA<CommandFailed>()));
    expect(player.current?.id, 's1');
  });

  test('with shuffle on, a jump goes by the play order', () async {
    const three = [...songs, Song(id: 's3', title: 'Three')];
    await player.playQueue(three);
    await player.setShuffle(true);
    expect(player.queue.map((song) => song.id), ['s1', 's3', 's2']); // the fake's shuffle
    await player.jump(1);
    expect(player.current?.id, 's3');
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

  test('next after the last track goes to the first, unless repeat is off', () async {
    await player.playQueue(songs, index: 1);
    await expectLater(player.next(), throwsA(isA<CommandFailed>()));
    await player.setRepeat(Repeat.all);
    await player.next();
    expect(player.index, 0);
    await player.setRepeat(Repeat.one);
    await player.next();
    expect(player.index, 1);
  });

  test('shuffle reorders the queue, keeping the current song, and off puts it back', () async {
    const three = [...songs, Song(id: 's3', title: 'Three')];
    await player.playQueue(three, index: 1);
    reports.clear();
    await player.setShuffle(true);
    expect(player.shuffle, isTrue);
    expect(player.queue.map((song) => song.id), ['s2', 's3', 's1']); // the fake's shuffle
    expect(player.current?.id, 's2');
    // The queue goes once, in the report after the change; the others leave it out.
    expect(reports.lastWhere((report) => report.queue != null).queue?.map((item) => item.id), ['s2', 's3', 's1']);
    expect(reports.last.shuffle, isTrue);
    await player.setShuffle(false);
    expect(player.queue.map((song) => song.id), ['s1', 's2', 's3']);
    expect(player.current?.id, 's2');
    expect(reports.last.shuffle, isFalse);
  });

  test('obeys setRepeat and setShuffle, and reports both', () async {
    await player.playQueue(songs);
    await player.obey(const Command.setRepeat(Repeat.one));
    expect(player.repeat, Repeat.one);
    expect(reports.last.repeat, Repeat.one);
    await player.obey(const Command.setShuffle(true));
    expect(player.shuffle, isTrue);
    expect(reports.last.shuffle, isTrue);
  });
}
