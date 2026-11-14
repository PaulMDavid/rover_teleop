part of 'main.dart';

/// Record page (swipe up from Wheels; navigation_ws #29): starts and stops a bag on orintwo
/// through `phone_ctl.sh record …` over the System page's ssh (record.dart). Left: the
/// preset (default preselected), its groups as checkboxes, "All topics…" for single
/// topics. Right: ● START, ■ STOP (with a confirm) and the live status `record status`
/// streams while the page shows. The big STOP stops the recording only; the mux STOP
/// (the rover) is the small red "MUX STOP" in the header.
class RecordPage extends StatelessWidget {
  const RecordPage({super.key, required this.ctl, required this.onStop, this.onWheels});

  final RecordController ctl;

  /// The mux STOP (set_mode stop), small in the header.
  final VoidCallback onStop;
  final VoidCallback? onWheels;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ctl,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(height: 40, child: _header()),
              const SizedBox(height: 4),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 5, child: _selection(context)),
                  const SizedBox(width: 16),
                  Expanded(flex: 4, child: _right(context)),
                ]),
              ),
            ]),
          ),
        ),
      );

  Widget _header() {
    final s = ctl.status;
    final compact = TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8));
    final (String state, Color color) = s == null
        ? (ctl.attached ? 'status…' : (ctl.statusError != null ? 'no status' : '—'), dim)
        : s.recording
            ? ('● recording ${fmtElapsed(s.elapsedS)}', bad)
            : ('○ not recording', dim);
    final short = state.replaceFirst('● recording', '● REC').replaceFirst('○ not recording', '○ idle');
    final bag = s?.bag == null ? '' : (s!.recording ? s.bag! : 'last: ${s.bag}');
    return Row(children: [
      if (onWheels != null) TextButton(onPressed: onWheels, style: compact, child: const Text('⌃ Wheels')),
      const Text('RECORD', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 2)),
      const SizedBox(width: 12),
      Expanded(
        child: _NoPageSwipe(
          // tap: ask orintwo again (e.g. after a recording was started elsewhere)
          child: GestureDetector(
            onTap: ctl.attach,
            // narrow phone: "● REC 00:12:41" so the bag name keeps some room
            child: LayoutBuilder(builder: (context, box) => Row(children: [
              Text(box.maxWidth < 330 ? short : state,
                  key: const Key('rec-state'),
                  style: TextStyle(color: color, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 12),
              Flexible(
                child: Text(bag,
                    key: const Key('rec-bag'), overflow: TextOverflow.ellipsis, style: const TextStyle(color: dim)),
              ),
            ])),
          ),
        ),
      ),
      const SizedBox(width: 8),
      _NoPageSwipe(child: SizedBox(width: 96, child: StopButton(onStop: onStop, height: 30, label: 'MUX STOP', fontSize: 13))),
    ]);
  }

  // -------------------------------------------------------------------------------------
  // left: preset, groups, all topics

  Widget _selection(BuildContext context) {
    final presets = ctl.presets;
    Widget body;
    if (presets.isEmpty) {
      body = Center(
        child: ctl.presetsLoading || ctl.presetsError == null
            ? const Text('loading presets…', style: TextStyle(color: dim))
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_words(ctl.presetsError!),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _color(ctl.presetsError!.level), fontSize: 13)),
                const SizedBox(height: 6),
                _NoPageSwipe(child: OutlinedButton(onPressed: ctl.loadPresets, child: const Text('Retry'))),
              ]),
      );
    } else {
      final edit = ctl.canEdit;
      final extra = ctl.extraTopics;
      final diff = ctl.diff;
      final adds = diff.where((d) => d.startsWith('+')).length, drops = diff.length - adds;
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Text('Preset', style: TextStyle(color: dim)),
          const SizedBox(width: 10),
          Expanded(
            child: _NoPageSwipe(
              child: DropdownButton<String>(
                key: const Key('rec-preset'),
                value: ctl.preset,
                isExpanded: true,
                isDense: true,
                underline: const SizedBox(),
                onChanged: edit ? (v) => v == null ? null : ctl.selectPreset(v) : null,
                items: [
                  for (final p in presets)
                    DropdownMenuItem(
                        value: p.name,
                        child: Text(p.label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                ],
              ),
            ),
          ),
        ]),
        const Divider(color: line, height: 10),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: [
            for (final g in ctl.groups) _groupRow(g, edit),
            if (extra.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
                child: Text('+ ${extra.length} more: ${extra.join(', ')}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: accent, fontSize: 12)),
              ),
          ]),
        ),
        const SizedBox(height: 4),
        _NoPageSwipe(
          child: SizedBox(
            height: 34,
            child: OutlinedButton(
              onPressed: () => _allTopics(context),
              style: OutlinedButton.styleFrom(
                backgroundColor: panel,
                side: const BorderSide(color: line, width: 2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                foregroundColor: Colors.white,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                'All topics…  ${ctl.selected.length} selected${diff.isEmpty ? '' : ' (+$adds −$drops)'}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        if (ctl.recording)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
                'recording ${ctl.status!.preset ?? '?'} · ${ctl.status!.topics} topics: the selection applies to the next start',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: dim, fontSize: 11)),
          ),
      ]);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(color: panel, border: Border.all(color: line), borderRadius: BorderRadius.circular(10)),
      child: body,
    );
  }

  Widget _groupRow(RecGroup g, bool edit) {
    final v = ctl.groupState(g);
    return _NoPageSwipe(
      child: InkWell(
        key: Key('rec-group-${g.name}'),
        onTap: edit ? () => ctl.setGroup(g, v != true) : null,
        child: SizedBox(
          height: 32,
          child: Row(children: [
            SizedBox(
              width: 32,
              child: Checkbox(
                value: v,
                tristate: true,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: edit ? (_) => ctl.setGroup(g, v != true) : null,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(g.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w600, color: edit ? null : dim)),
            ),
            Text(v == null ? '${g.topics.where(ctl.selected.contains).length}/${g.topics.length}' : '${g.topics.length}',
                style: const TextStyle(color: dim, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Future<void> _allTopics(BuildContext context) async {
    if (ctl.topics == null && !ctl.topicsLoading) ctl.loadTopics();
    await showDialog<void>(context: context, builder: (_) => Dialog.fullscreen(child: AllTopicsSheet(ctl: ctl)));
  }

  // -------------------------------------------------------------------------------------
  // right: START / STOP, live status

  Widget _right(BuildContext context) {
    final op = ctl.op;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 48,
        child: _NoPageSwipe(
          child: _big(op == 'start' ? '● START …' : '● START', ctl.canStart ? ctl.start : null, color: ok),
        ),
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: 48,
        child: _NoPageSwipe(
          child: _big(op == 'stop' ? '■ STOP …' : '■ STOP', ctl.canStop ? () => _confirmStop(context) : null, color: bad),
        ),
      ),
      const SizedBox(height: 6),
      Expanded(child: _status(context)),
    ]);
  }

  Widget _status(BuildContext context) {
    final s = ctl.status;
    final rec = s?.recording == true;
    final silent = s?.silent;
    final lines = <Widget>[
      _kv('Bag', rec || s?.sizeMb != null ? '${fmtSize(s?.sizeMb)}  ·  ${fmtRate(s?.rateMbps)}' : '—', key: 'rec-size'),
      _kv('SSD', s?.freeGb == null ? '—' : '${s!.freeGb!.toStringAsFixed(0)} GB free', key: 'rec-free'),
      if (rec)
        Text(s!.leftH == null ? '≈ ? h left (bag still empty)' : '≈ ${fmtLeft(s.leftH)} left at this rate',
            key: const Key('rec-left'), style: const TextStyle(fontSize: 14)),
      if (rec && s!.inputMbps != null)
        Text('in ${fmtRate(s.inputMbps)} before compression', style: const TextStyle(color: dim, fontSize: 12)),
      if (rec) ...[
        const SizedBox(height: 2),
        if (silent == null)
          const Text('… checking topics', key: Key('rec-silent'), style: TextStyle(color: dim, fontSize: 13))
        else if (silent.isEmpty)
          const Text('✓ all topics publishing', key: Key('rec-silent'), style: TextStyle(color: ok, fontSize: 13))
        else
          Column(key: const Key('rec-silent'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final t in silent)
              Text('✗ $t NO MESSAGES',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: bad, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        if (s!.unwatched.isNotEmpty)
          Text('${s.unwatched.length} topics not watched (type not loadable)',
              style: const TextStyle(color: dim, fontSize: 11)),
      ],
      if (s != null && s.unclosed.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _NoPageSwipe(
            child: GestureDetector(
              onTap: () => _showUnclosed(context, s.unclosed),
              child: Container(
                key: const Key('rec-unclosed'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B2A0A),
                  border: Border.all(color: warn),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('⚠ unclosed bag: ${s.unclosed.join(', ')} — tap for recovery',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: warn, fontSize: 12)),
              ),
            ),
          ),
        ),
      if (ctl.op != null && ctl.opLine != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('⟳ ${ctl.opLine}',
              key: const Key('rec-op'), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: dim, fontSize: 12)),
        ),
      if (ctl.outcome != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(_words(ctl.outcome!),
              key: const Key('rec-outcome'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _color(ctl.outcome!.level), fontSize: 12)),
        ),
      if (ctl.statusError != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('status: ${ctl.statusError}${ctl.visible && !ctl.statusError!.startsWith('refused') ? ' (retrying)' : ''}',
              key: const Key('rec-status-error'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: bad, fontSize: 12)),
        ),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(color: panel, border: Border.all(color: line), borderRadius: BorderRadius.circular(10)),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: lines),
      ),
    );
  }

  /// busy / refused reasons start with that word already: capitalised, not repeated.
  static String _words(RecOutcome o) => switch (o.level) {
        'busy' => o.text.startsWith('busy') ? 'Busy${o.text.substring(4)}' : 'Busy: ${o.text}',
        'refused' => o.text.startsWith('refused') ? 'Refused${o.text.substring(7)}' : 'Refused: ${o.text}',
        _ => o.text,
      };

  static Color _color(String level) => switch (level) {
        'ok' => ok,
        'warn' || 'busy' => warn,
        _ => bad,
      };

  static Widget _kv(String k, String v, {required String key}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          SizedBox(width: 44, child: Text(k, style: const TextStyle(color: dim, fontSize: 14))),
          Expanded(
            child: Text(v,
                key: Key(key),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ]),
      );

  static Widget _big(String label, VoidCallback? onPressed, {required Color color}) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: onPressed == null ? panel : (color == bad ? const Color(0xFF7F1D1D) : const Color(0xFF14532D)),
          side: BorderSide(color: onPressed == null ? line : color, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          foregroundColor: Colors.white,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 2)),
      );

  Future<void> _confirmStop(BuildContext context) async {
    final bag = ctl.status?.bag;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop recording?'),
        content: Text('${ctl.recording && bag != null ? bag : 'The recording'} is closed: the last chunk is '
            'compressed and metadata written (takes a few seconds). The rover is not stopped.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep recording')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: bad),
            child: const Text('Stop recording'),
          ),
        ],
      ),
    );
    if (yes == true) ctl.stop();
  }

  Future<void> _showUnclosed(BuildContext context, List<String> bags) => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Unclosed bag'),
          content: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${bags.join(', ')} has chunks but no metadata.yaml (power cut or killed recorder). '
                  'Recover on orintwo:'),
              const SizedBox(height: 8),
              for (final b in bags)
                SelectableText(
                  'docker run --rm -v /mnt/ssd/pdavid/bags:/bags --entrypoint bash zed2i_rec:2026-11-14 -c '
                  "'source /opt/ros/humble/setup.bash; ros2 bag reindex -s sqlite3 /bags/$b'",
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        ),
      );
}

/// "All topics…": every live topic (`record topics`: type, Hz, MB/s over 3 s) plus the
/// selected ones that aren't live, the selection ticked. Ticking / unticking changes the
/// selection, which START sends as the preset plus `+/topic` / `-/topic`.
class AllTopicsSheet extends StatefulWidget {
  const AllTopicsSheet({super.key, required this.ctl});

  final RecordController ctl;

  @override
  State<AllTopicsSheet> createState() => _AllTopicsSheetState();
}

class _AllTopicsSheetState extends State<AllTopicsSheet> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([widget.ctl, search]),
        builder: (context, _) {
          final ctl = widget.ctl;
          final live = ctl.topics ?? const <RecTopic>[];
          final liveNames = {for (final t in live) t.name};
          final missing = ctl.selected.where((t) => !liveNames.contains(t)).toList()..sort();
          final q = search.text.trim().toLowerCase();
          bool hit(String name, String type) => q.isEmpty || name.toLowerCase().contains(q) || type.toLowerCase().contains(q);
          final shown = [
            for (final t in live)
              if (hit(t.name, t.type)) t,
          ];
          final shownMissing = missing.where((t) => hit(t, '')).toList();
          final edit = ctl.canEdit;
          String note;
          if (ctl.topicsLoading) {
            note = 'sampling every live topic (≈ 10 s)…';
          } else if (ctl.topicsError != null) {
            note = RecordPage._words(ctl.topicsError!);
          } else {
            note = '${live.length} live';
          }
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  height: 44,
                  child: Row(children: [
                    const Text('ALL TOPICS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 2)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const Key('rec-search'),
                        controller: search,
                        decoration: const InputDecoration(
                            isDense: true, prefixIcon: Icon(Icons.search, size: 18), hintText: 'search name or type'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('${ctl.selected.length} selected', style: const TextStyle(color: dim)),
                    IconButton(
                      tooltip: 'Sample again',
                      onPressed: ctl.topicsLoading ? null : ctl.loadTopics,
                      icon: const Icon(Icons.refresh),
                    ),
                    FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                  ]),
                ),
                Row(children: [
                  Expanded(
                    child: Text(
                      edit ? note : '$note · read-only while recording or starting',
                      key: const Key('rec-topics-note'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: ctl.topicsError != null ? RecordPage._color(ctl.topicsError!.level) : dim, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 60, child: Text('Hz', textAlign: TextAlign.right, style: TextStyle(color: dim, fontSize: 12))),
                  const SizedBox(width: 70, child: Text('MB/s', textAlign: TextAlign.right, style: TextStyle(color: dim, fontSize: 12))),
                ]),
                const Divider(color: line, height: 6),
                Expanded(
                  child: ListView(children: [
                    for (final t in shown) _row(t.name, t.type, fmtHz(t.hz), fmtMbps(t.mbps), edit),
                    for (final t in shownMissing) _row(t, 'not live', '–', '–', edit, missing: true),
                  ]),
                ),
              ]),
            ),
          );
        },
      );

  Widget _row(String name, String type, String hz, String mbps, bool edit, {bool missing = false}) {
    final ctl = widget.ctl;
    final on = ctl.selected.contains(name);
    const num = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    return InkWell(
      key: Key('rec-topic-$name'),
      onTap: edit ? () => ctl.setTopic(name, !on) : null,
      child: SizedBox(
        height: 36,
        child: Row(children: [
          SizedBox(
            width: 32,
            child: Checkbox(
              value: on,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: edit ? (v) => ctl.setTopic(name, v == true) : null,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 5,
            child: Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: missing ? warn : null)),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(type, overflow: TextOverflow.ellipsis, style: const TextStyle(color: dim, fontSize: 12)),
          ),
          SizedBox(width: 60, child: Text(hz, textAlign: TextAlign.right, style: num)),
          SizedBox(width: 70, child: Text(mbps, textAlign: TextAlign.right, style: num)),
        ]),
      ),
    );
  }
}
