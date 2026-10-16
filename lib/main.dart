import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const EditProApp());

const accent = Color(0xFF4F8CFF);

class EditProApp extends StatelessWidget {
  const EditProApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'EditPro',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0E0F12),
          colorScheme:
              ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
        ),
        home: const EditorPage(),
      );
}

/// A piece of the source video, in source milliseconds.
class Seg {
  int start, end;
  Seg(this.start, this.end);
  int get len => end - start;
}

/// Keyframe on the edited timeline. x/y are fractions of frame size, s is scale.
class Kf {
  int t;
  double x, y, s;
  Kf(this.t, this.x, this.y, this.s);
}

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  static const channel = MethodChannel('editpro/export');

  VideoPlayerController? vc;
  String? path;
  int srcDur = 0;
  List<Seg> segs = [];
  List<Kf> keys = [];
  int sel = 0; // selected segment
  int cur = 0; // segment currently playing
  int head = 0; // playhead, edited-timeline ms
  bool playing = false;
  bool exporting = false;
  int tab = 0;
  Timer? timer;

  int get total => segs.fold(0, (a, s) => a + s.len);

  int offsetOf(int i) {
    var o = 0;
    for (var k = 0; k < i; k++) {
      o += segs[k].len;
    }
    return o;
  }

  int cl(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  /// Which segment holds timeline time t, and where that segment starts.
  (int, int) locate(int t) {
    var o = 0;
    for (var i = 0; i < segs.length; i++) {
      if (t < o + segs[i].len || i == segs.length - 1) return (i, o);
      o += segs[i].len;
    }
    return (0, 0);
  }

  void msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  // ---------- import ----------
  Future<void> pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.video);
    final p = r?.files.single.path;
    if (p == null) return;
    timer?.cancel();
    await vc?.dispose();
    final c = VideoPlayerController.file(File(p));
    await c.initialize();
    setState(() {
      vc = c;
      path = p;
      srcDur = c.value.duration.inMilliseconds;
      segs = [Seg(0, srcDur)];
      keys = [];
      sel = 0;
      cur = 0;
      head = 0;
      playing = false;
    });
    timer = Timer.periodic(const Duration(milliseconds: 33), (_) => tick());
  }

  // ---------- playback ----------
  void tick() {
    if (!playing || vc == null) return;
    final pos = vc!.value.position.inMilliseconds;
    if (pos >= segs[cur].end - 30) {
      if (cur + 1 < segs.length) {
        cur++;
        vc!.seekTo(Duration(milliseconds: segs[cur].start));
      } else {
        vc!.pause();
        playing = false;
        head = total;
      }
      setState(() {});
      return;
    }
    head = cl(offsetOf(cur) + pos - segs[cur].start, 0, total);
    setState(() {});
  }

  void seek(int t) {
    t = cl(t, 0, total);
    final (i, o) = locate(t);
    cur = i;
    vc?.seekTo(Duration(milliseconds: segs[i].start + cl(t - o, 0, segs[i].len)));
    setState(() => head = t);
  }

  void togglePlay() {
    final c = vc;
    if (c == null) return;
    if (playing) {
      c.pause();
      setState(() => playing = false);
    } else {
      if (head >= total - 30) seek(0);
      c.play();
      setState(() => playing = true);
    }
  }

  // ---------- cut / trim ----------
  void split() {
    final (i, o) = locate(head);
    final s = segs[i];
    final into = head - o;
    if (into < 300 || s.len - into < 300) {
      msg('Move the playhead inside a clip to split');
      return;
    }
    final src = s.start + into;
    setState(() {
      segs.replaceRange(i, i + 1, [Seg(s.start, src), Seg(src, s.end)]);
      sel = i + 1;
    });
  }

  void deleteSeg() {
    if (segs.length < 2) {
      msg('Keep at least one clip');
      return;
    }
    final o = offsetOf(sel), l = segs[sel].len;
    setState(() {
      segs.removeAt(sel);
      keys.removeWhere((k) => k.t >= o && k.t < o + l);
      for (final k in keys) {
        if (k.t >= o + l) k.t -= l;
      }
      sel = min(sel, segs.length - 1);
    });
    seek(cl(o, 0, total));
  }

  // ---------- keyframes ----------
  (double, double, double) valueAt(int t) {
    if (keys.isEmpty) return (0, 0, 1);
    final k = [...keys]..sort((a, b) => a.t.compareTo(b.t));
    if (t <= k.first.t) return (k.first.x, k.first.y, k.first.s);
    if (t >= k.last.t) return (k.last.x, k.last.y, k.last.s);
    for (var i = 0; i < k.length - 1; i++) {
      final a = k[i], b = k[i + 1];
      if (t >= a.t && t <= b.t) {
        final f = b.t == a.t ? 0.0 : (t - a.t) / (b.t - a.t);
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.s + (b.s - a.s) * f);
      }
    }
    return (0, 0, 1);
  }

  Kf? keyNearHead() => keys.where((k) => (k.t - head).abs() < 60).firstOrNull;

  void edit({double? x, double? y, double? s}) {
    final v = valueAt(head);
    var k = keyNearHead();
    if (k == null) {
      k = Kf(head, v.$1, v.$2, v.$3);
      keys.add(k);
    }
    if (x != null) k.x = x;
    if (y != null) k.y = y;
    if (s != null) k.s = s;
    setState(() {});
  }

  void deleteKey() {
    final k = keyNearHead();
    if (k == null) {
      msg('No keyframe at the playhead');
      return;
    }
    setState(() => keys.remove(k));
  }

  // ---------- export ----------
  Future<void> export() async {
    if (vc == null || exporting) return;
    vc!.pause();
    setState(() {
      playing = false;
      exporting = true;
    });
    try {
      await channel.invokeMethod('export', {
        'path': path,
        'segments': [
          for (var i = 0; i < segs.length; i++)
            {'start': segs[i].start, 'end': segs[i].end, 'offset': offsetOf(i)}
        ],
        'keys': [
          for (final k in keys) {'t': k.t, 'x': k.x, 'y': k.y, 's': k.s}
        ],
      });
      msg('Saved to Movies/EditPro');
    } on PlatformException catch (e) {
      msg('Export failed: ${e.message}');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    vc?.dispose();
    super.dispose();
  }

  String fmt(int ms) {
    final s = ms / 1000;
    final m = s ~/ 60;
    return '$m:${(s % 60).toStringAsFixed(1).padLeft(4, '0')}';
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final loaded = vc != null;
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          Column(children: [
            topBar(loaded),
            Expanded(child: loaded ? preview() : emptyState()),
            if (loaded) ...[
              transport(),
              timeline(),
              const SizedBox(height: 8),
              tabs(),
              SizedBox(height: 170, child: tab == 0 ? clipPanel() : keyPanel()),
            ],
          ]),
          if (exporting)
            Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: const Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Exporting MP4…'),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget topBar(bool loaded) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(children: [
          const Text('EditPro',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const Spacer(),
          IconButton.filledTonal(
              onPressed: pick, icon: const Icon(Icons.video_library_outlined)),
          const SizedBox(width: 8),
          FilledButton.icon(
              onPressed: loaded ? export : null,
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('Export')),
        ]),
      );

  Widget emptyState() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.movie_creation_outlined, size: 64, color: Colors.white38),
          const SizedBox(height: 16),
          FilledButton.icon(
              onPressed: pick,
              icon: const Icon(Icons.add),
              label: const Text('Import a video')),
        ]),
      );

  Widget preview() {
    final c = vc!;
    final v = valueAt(head);
    return Center(
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: LayoutBuilder(
          builder: (ctx, bc) => ClipRect(
            child: Transform.translate(
              offset: Offset(v.$1 * bc.maxWidth, v.$2 * bc.maxHeight),
              child: Transform.scale(scale: v.$3, child: VideoPlayer(c)),
            ),
          ),
        ),
      ),
    );
  }

  Widget transport() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(onPressed: () => seek(0), icon: const Icon(Icons.skip_previous)),
          IconButton.filled(
              iconSize: 32,
              onPressed: togglePlay,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow)),
          const SizedBox(width: 12),
          Text('${fmt(head)} / ${fmt(total)}',
              style: const TextStyle(color: Colors.white70)),
        ]),
      );

  Widget timeline() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LayoutBuilder(builder: (ctx, bc) {
          final w = bc.maxWidth;
          final ppm = w / max(total, 1);
          int tAt(double dx) => (dx / ppm).round();
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final t = tAt(d.localPosition.dx);
              seek(t);
              setState(() => sel = locate(cl(t, 0, total)).$1);
            },
            onHorizontalDragUpdate: (d) => seek(tAt(d.localPosition.dx)),
            child: SizedBox(
              height: 92,
              child: Stack(children: [
                for (var i = 0; i < segs.length; i++)
                  Positioned(
                    left: offsetOf(i) * ppm,
                    width: max(segs[i].len * ppm - 2, 2),
                    top: 24,
                    height: 56,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: i == sel ? accent.withAlpha(140) : const Color(0xFF2A2D35),
                        border: Border.all(
                            color: i == sel ? accent : Colors.white24,
                            width: i == sel ? 2 : 1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('${(segs[i].len / 1000).toStringAsFixed(1)}s',
                          style: const TextStyle(fontSize: 11)),
                    ),
                  ),
                for (final k in keys)
                  Positioned(
                    left: k.t * ppm - 5,
                    top: 8,
                    child: Transform.rotate(
                        angle: pi / 4,
                        child: Container(width: 10, height: 10, color: Colors.amber)),
                  ),
                Positioned(
                    left: head * ppm - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 2, color: Colors.white)),
              ]),
            ),
          );
        }),
      );

  Widget tabs() => SegmentedButton<int>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 0, icon: Icon(Icons.content_cut), label: Text('Clip')),
          ButtonSegment(value: 1, icon: Icon(Icons.timeline), label: Text('Keyframes')),
        ],
        selected: {tab},
        onSelectionChanged: (s) => setState(() => tab = s.first),
      );

  Widget clipPanel() {
    final s = segs[sel];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: FilledButton.tonalIcon(
                  onPressed: split,
                  icon: const Icon(Icons.call_split),
                  label: const Text('Split at playhead'))),
          const SizedBox(width: 12),
          Expanded(
              child: FilledButton.tonalIcon(
                  onPressed: deleteSeg,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete clip'))),
        ]),
        const SizedBox(height: 12),
        Text('Trim selected clip: ${fmt(s.start)} – ${fmt(s.end)}',
            style: const TextStyle(color: Colors.white70)),
        RangeSlider(
          min: 0,
          max: srcDur.toDouble(),
          values: RangeValues(s.start.toDouble(), s.end.toDouble()),
          onChanged: (r) {
            final a = r.start.round(), b = r.end.round();
            if (b - a < 300) return;
            setState(() {
              s.start = a;
              s.end = b;
            });
          },
          onChangeEnd: (_) {
            keys.removeWhere((k) => k.t > total);
            seek(offsetOf(sel));
          },
        ),
      ]),
    );
  }

  Widget slider(String label, double v, double lo, double hi, ValueChanged<double> f) =>
      Row(children: [
        SizedBox(width: 74, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(child: Slider(value: v.clamp(lo, hi), min: lo, max: hi, onChanged: f)),
        SizedBox(
            width: 40,
            child: Text(v.toStringAsFixed(2),
                style: const TextStyle(fontSize: 12, color: Colors.white70))),
      ]);

  Widget keyPanel() {
    final v = valueAt(head);
    final has = keyNearHead() != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Column(children: [
        Row(children: [
          Expanded(
              child: Text(
                  has
                      ? 'Keyframe at playhead'
                      : 'Move the playhead, then drag a slider to add a keyframe',
                  style: const TextStyle(color: Colors.white70, fontSize: 12))),
          TextButton.icon(
              onPressed: deleteKey,
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Remove')),
        ]),
        slider('Position X', v.$1, -1, 1, (x) => edit(x: x)),
        slider('Position Y', v.$2, -1, 1, (y) => edit(y: y)),
        slider('Scale', v.$3, 0.5, 3, (s) => edit(s: s)),
      ]),
    );
  }
}
