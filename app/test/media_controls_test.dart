import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/connect/connect.dart';
import 'package:segue/player/media_controls.dart';
import 'package:segue/player/player.dart';
import 'package:segue/server/models.dart';
import 'package:segue/subsonic/api.dart';

import 'fakes.dart';

const songs = [
  Song(id: 's1', title: 'Dream On', artist: 'Aerosmith', duration: Duration(minutes: 4)),
  Song(id: 's2', title: 'Other', artist: 'Someone', duration: Duration(minutes: 3)),
];

void main() {
  test("the system controls show this device's playback and command it", () async {
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      const SubsonicCredentials(username: 'a', token: 't', salt: 's'),
      client: MockClient((_) async => http.Response('', 404)),
    );
    final player = PlayerController(FakeEngine(), api);
    final controls = MediaControls()..attach(ConnectController(player: player), api);
    expect(controls.mediaItem.value, isNull);

    await player.playQueue(songs, position: const Duration(seconds: 30));
    expect(controls.mediaItem.value?.title, 'Dream On');
    expect(controls.mediaItem.value?.artist, 'Aerosmith');
    expect(controls.mediaItem.value?.duration, const Duration(minutes: 4));
    expect(controls.playbackState.value.playing, isTrue);
    expect(controls.playbackState.value.updatePosition.inSeconds, 30);

    await controls.pause();
    expect(player.playing, isFalse);
    expect(controls.playbackState.value.playing, isFalse);
    await controls.play();
    expect(player.playing, isTrue);
    await controls.skipToNext();
    expect(controls.mediaItem.value?.title, 'Other');
    await controls.seek(const Duration(seconds: 90));
    expect(player.position.inSeconds, greaterThanOrEqualTo(90));

    controls.attach(null, null); // signing out
    expect(controls.mediaItem.value, isNull);
  });
}
