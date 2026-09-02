import 'package:flutter_test/flutter_test.dart';

import 'package:kite/call_center.dart';
import 'package:kite/models.dart';

void main() {
  // Neutralise le polling WebSocket de KiteApi.realtime() : le test pilote
  // CallCenter via _onEvent, pas via le transport.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CallCenter route les signaux et réponses vers les bons appels', () async {
    final center = CallCenter.instance;
    addTearDown(center.dispose);

    final received = <CallSignalEvent>[];
    final sub = center.signals.listen(received.add);
    addTearDown(sub.cancel);

    final responded = <Map<String, dynamic>>[];
    final respSub = center.responses.listen(responded.add);
    addTearDown(respSub.cancel);

    // Signal pour un autre appel : ignoré par le filtre du moteur (callId).
    center.handleEvent(ServerEvent('call_signal', {
      'callId': 'other-call',
      'kind': 'offer',
      'from': 'u-emma',
      'payload': {'sdp': 'x'},
    }));

    // Signal du bon appel : routé + backlog.
    center.handleEvent(ServerEvent('call_signal', {
      'callId': 'call-1',
      'kind': 'answer',
      'from': 'u-lucas',
      'payload': {'sdp': 'v=0', 'type': 'answer'},
    }));

    // Signal malformé : ignoré proprement.
    center.handleEvent(const ServerEvent('call_signal', {}));

    expect(center.signalBacklog('call-1'), hasLength(1));
    // Le backlog est par appel : celui de 'other-call' reste disponible
    // pour un moteur qui s'abonnerait en retard sur CET appel.
    expect(center.signalBacklog('other-call'), hasLength(1));

    // Réponse accepted : diffusée, la sonnerie reste affichée.
    center.handleEvent(ServerEvent('call_respond', {'id': 'call-1', 'status': 'accepted'}));

    // Un appel entrant sonne.
    center.handleEvent(ServerEvent('call', {
      'id': 'call-1',
      'callerName': 'Lucas Martin',
      'chatId': 'c-lucas',
      'kind': 'video',
    }));
    expect(center.current.value?.callerName, 'Lucas Martin');
    expect(center.current.value?.group, isFalse);

    // ended ferme la sonnerie du même appel.
    center.handleEvent(ServerEvent('call_respond', {'id': 'call-1', 'status': 'ended'}));
    expect(center.current.value, isNull);

    // Les streams broadcast délivrent en asynchrone : on laisse passer un tour.
    await Future<void>.delayed(Duration.zero);
    // Le stream diffuse tous les signaux ; le filtrage par callId est fait
    // par le moteur (signals.where((s) => s.callId == callId)).
    expect(received.map((s) => s.kind), ['offer', 'answer']);
    expect(received.first.callId, 'other-call');
    expect(received.last.callId, 'call-1');
    expect(responded.map((r) => r['status']), ['accepted', 'ended']);
  });
}
