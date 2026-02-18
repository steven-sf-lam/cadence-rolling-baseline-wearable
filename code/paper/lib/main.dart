import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'csv_download.dart';

void main() {
  runApp(const PaperApp());
}

class PaperApp extends StatelessWidget {
  const PaperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Stealth Miles Paper Experiments',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF005A6B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const ExperimentPage(),
    );
  }
}

class ExperimentPage extends StatefulWidget {
  const ExperimentPage({super.key});

  @override
  State<ExperimentPage> createState() => _ExperimentPageState();
}

class _ExperimentPageState extends State<ExperimentPage> {
  final TextEditingController _maxHrController = TextEditingController(
    text: '200',
  );
  final TextEditingController _restHrController = TextEditingController(
    text: '54',
  );
  final TextEditingController _z1Controller = TextEditingController(
    text: '59',
  );
  final TextEditingController _z2Controller = TextEditingController(
    text: '74',
  );
  final TextEditingController _z3Controller = TextEditingController(
    text: '84',
  );
  final TextEditingController _z4Controller = TextEditingController(
    text: '88',
  );
  final TextEditingController _z5Controller = TextEditingController(
    text: '95',
  );
  final TextEditingController _strideController = TextEditingController(
    text: '140',
  );
  final TextEditingController _windowController = TextEditingController(
    text: '30',
  );
  final TextEditingController _cmpCadence1Controller = TextEditingController(
    text: '125',
  );
  final TextEditingController _cmpCadence2Controller = TextEditingController(
    text: '140',
  );
  final TextEditingController _cmpCadence3Controller = TextEditingController(
    text: '150',
  );
  final StravaAuthService _authService = StravaAuthService();

  List<RunSample> _samples = <RunSample>[];
  AnalysisResult? _result;
  String? _error;
  String? _status;
  bool _loading = false;
  bool _checkedAuthCode = false;
  int _rowsPerPage = PaginatedDataTable.defaultRowsPerPage;

  @override
  void initState() {
    super.initState();
    _initializeAuthAndData();
  }

  @override
  void dispose() {
    _maxHrController.dispose();
    _restHrController.dispose();
    _z1Controller.dispose();
    _z2Controller.dispose();
    _z3Controller.dispose();
    _z4Controller.dispose();
    _z5Controller.dispose();
    _strideController.dispose();
    _windowController.dispose();
    _cmpCadence1Controller.dispose();
    _cmpCadence2Controller.dispose();
    _cmpCadence3Controller.dispose();
    super.dispose();
  }

  Future<void> _initializeAuthAndData() async {
    if (_checkedAuthCode) return;
    _checkedAuthCode = true;

    final Uri base = Uri.base;
    final String? code = base.queryParameters['code'];
    if (code != null && code.isNotEmpty) {
      setState(() {
        _status = 'Exchanging Strava authorization code...';
      });
      try {
        await _authService.exchangeCodeForTokens(
          code: code,
          redirectUri: _redirectUri,
        );
        setState(() {
          _status = 'Strava connected. Fetching activities...';
        });
        await _fetchFromStravaAndAnalyze();
      } catch (e) {
        setState(() {
          _error = e.toString();
          _status = null;
        });
      }
      return;
    }

    final String? token = await _authService.getAccessToken();
    if (token != null && token.isNotEmpty) {
      setState(() {
        _status = 'Using existing Strava session. Fetching activities...';
      });
      await _fetchFromStravaAndAnalyze();
    }
  }

  String get _redirectUri {
    final Uri b = Uri.base;
    return Uri(
      scheme: b.scheme,
      host: b.host,
      port: b.hasPort ? b.port : null,
      path: b.path,
    ).toString();
  }

  Future<void> _connectStrava() async {
    final Uri authUrl = StravaAuthService.buildAuthorizeUri(
      redirectUri: _redirectUri,
    );
    await launchUrl(authUrl, webOnlyWindowName: '_self');
  }

  Future<void> _disconnectStrava() async {
    await _authService.clearTokens();
    setState(() {
      _samples = <RunSample>[];
      _result = null;
      _status = 'Strava tokens cleared.';
      _error = null;
    });
  }

  Future<void> _fetchFromStravaAndAnalyze() async {
    setState(() {
      _loading = true;
      _error = null;
      _status = 'Loading activities and streams from Strava...';
    });

    try {
      final String? token = await _authService.getAccessToken();
      if (token == null || token.isEmpty) {
        throw Exception('No Strava token found. Click Connect Strava first.');
      }

      final StravaApiClient api = StravaApiClient(_authService);
      final List<Map<String, dynamic>> activities = await api
          .fetchRunActivities();

      final List<RunSample> built = <RunSample>[];
      int processed = 0;
      for (final Map<String, dynamic> activity in activities) {
        final String? runId = activity['id']?.toString();
        final DateTime? start = _parseDateTime(
          (activity['start_date'] ?? activity['start_date_local'])?.toString(),
        );
        if (runId == null || start == null) continue;

        final Map<String, dynamic>? streams = await api.fetchActivityStreams(
          runId,
        );
        if (streams == null || streams.isEmpty) continue;
        built.addAll(
          _buildSamplesFromStreams(
            runId: runId,
            startTime: start,
            streams: streams,
          ),
        );

        processed++;
        if (processed % 5 == 0 && mounted) {
          setState(() {
            _status = 'Processed $processed / ${activities.length} runs...';
          });
        }
      }

      if (built.isEmpty) {
        throw Exception('No valid stream samples found from Strava runs.');
      }
      built.sort((RunSample a, RunSample b) => a.ts.compareTo(b.ts));
      _runAnalysisOnSamples(
        built,
        statusMessage: 'Analysis done from ${activities.length} runs.',
      );
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<RunSample> _buildSamplesFromStreams({
    required String runId,
    required DateTime startTime,
    required Map<String, dynamic> streams,
  }) {
    final List<double> time = _extractStreamSeries(streams, 'time');
    final List<double> hr = _extractStreamSeries(streams, 'heartrate');
    final List<double> velocity = _extractStreamSeries(
      streams,
      'velocity_smooth',
    );
    final List<double> cadenceRaw = _extractStreamSeries(streams, 'cadence');
    final List<double> gradeRaw = _extractStreamSeries(streams, 'grade_smooth');

    final int len = <int>[
      time.length,
      hr.length,
      velocity.length,
      cadenceRaw.length,
    ].reduce(min);
    if (len < 20) return <RunSample>[];

    final List<RunSample> out = <RunSample>[];
    for (int i = 0; i < len; i++) {
      final double h = hr[i];
      final double v = velocity[i];
      final double c = cadenceRaw[i] * 2.0; // Strava cadence is often per-leg.
      if (!h.isFinite ||
          !v.isFinite ||
          !c.isFinite ||
          h <= 0 ||
          v <= 0 ||
          c <= 0) {
        continue;
      }

      final double paceSecPerKm = 1000 / v;
      if (!paceSecPerKm.isFinite || paceSecPerKm <= 0) continue;

      final DateTime ts = startTime.add(Duration(seconds: time[i].round()));
      final double? grade = (gradeRaw.length > i && gradeRaw[i].isFinite)
          ? gradeRaw[i] * 100.0
          : null;

      out.add(
        RunSample(
          runId: runId,
          ts: ts,
          startTime: startTime,
          hr: h,
          paceSecPerKm: paceSecPerKm,
          cadence: c,
          grade: grade,
        ),
      );
    }

    return out;
  }

  void _runAnalysisOnSamples(
    List<RunSample> samples, {
    required String statusMessage,
  }) {
    final int strideThreshold = _intFrom(_strideController.text, fallback: 140);
    final int maxHr = _intFrom(_maxHrController.text, fallback: 200);
    final int restHr = _intFrom(_restHrController.text, fallback: 54);
    final int windowDays = _intFrom(_windowController.text, fallback: 30);
    final List<double> bandLowerPercents = <double>[
      _doubleFrom(_z1Controller.text, fallback: 59),
      _doubleFrom(_z2Controller.text, fallback: 74),
      _doubleFrom(_z3Controller.text, fallback: 84),
      _doubleFrom(_z4Controller.text, fallback: 88),
      _doubleFrom(_z5Controller.text, fallback: 95),
    ];
    final List<int> compareCadences = <int>[
      _intFrom(_cmpCadence1Controller.text, fallback: 125),
      _intFrom(_cmpCadence2Controller.text, fallback: 140),
      _intFrom(_cmpCadence3Controller.text, fallback: 150),
    ];

    final AnalysisResult analysis = Analyzer(
      samples: samples,
      strideThreshold: strideThreshold,
      maxHr: maxHr,
      restHr: restHr,
      bandLowerPercents: bandLowerPercents,
      compareCadenceThresholds: compareCadences,
      windowDays: windowDays,
    ).run();

    setState(() {
      _samples = samples;
      _result = analysis;
      _status = statusMessage;
      _loading = false;
      _error = null;
    });
  }

  void _reanalyzeCurrentData() {
    if (_samples.isEmpty) {
      setState(() {
        _error = 'No loaded samples. Please Fetch & Analyze first.';
      });
      return;
    }
    try {
      _runAnalysisOnSamples(
        _samples,
        statusMessage: 'Re-analyzed using current A/B/C cadence thresholds.',
      );
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  void _downloadAnalyzedCsv() {
    if (_samples.isEmpty) {
      setState(() {
        _error = 'No loaded samples. Please Fetch & Analyze first.';
      });
      return;
    }
    if (!kIsWeb) {
      setState(() {
        _error = 'CSV download is available in web build.';
      });
      return;
    }

    final List<HRBand> bands = Analyzer._buildBands(<double>[
      _doubleFrom(_z1Controller.text, fallback: 59),
      _doubleFrom(_z2Controller.text, fallback: 74),
      _doubleFrom(_z3Controller.text, fallback: 84),
      _doubleFrom(_z4Controller.text, fallback: 88),
      _doubleFrom(_z5Controller.text, fallback: 95),
    ]);
    final int maxHr = _intFrom(_maxHrController.text, fallback: 200);
    final int restHr = _intFrom(_restHrController.text, fallback: 54);

    final StringBuffer sb = StringBuffer();
    sb.writeln(
      'run_id,ts,start_time,hr_bpm,pace_sec_per_km,pace_mm:ss_per_km,cadence_spm,grade_pct,intensity,hr_band',
    );

    for (final RunSample s in _samples) {
      final double intensity = _sampleIntensity(
        hr: s.hr,
        maxHr: maxHr,
        restHr: restHr,
      );
      final String band = _bandLabelForIntensity(intensity, bands);
      sb.writeln(
        <String>[
          _csvCell(s.runId),
          _csvCell(s.ts.toIso8601String()),
          _csvCell(s.startTime.toIso8601String()),
          s.hr.toStringAsFixed(1),
          s.paceSecPerKm.toStringAsFixed(3),
          _csvCell(_secPerKmToMmssPerKm(s.paceSecPerKm)),
          s.cadence.toStringAsFixed(1),
          s.grade?.toStringAsFixed(3) ?? '',
          intensity.toStringAsFixed(4),
          band,
        ].join(','),
      );
    }

    final DateTime now = DateTime.now();
    final String filename =
        'paper_analysis_data_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.csv';
    downloadCsv(filename, sb.toString());
    setState(() {
      _status = 'CSV downloaded: $filename';
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int compareA = _intFrom(_cmpCadence1Controller.text, fallback: 125);
    final int compareB = _intFrom(_cmpCadence2Controller.text, fallback: 140);
    final int compareC = _intFrom(_cmpCadence3Controller.text, fallback: 150);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stealth Miles Paper Experiment Dashboard'),
      ),
      body: Scrollbar(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
              Text(
                'Data source: Strava API (no CSV upload). OAuth and stream logic follows the existing app flow.',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  _numberInput(_maxHrController, 'Max HR'),
                  _numberInput(_restHrController, 'Rest HR'),
                  _numberInput(_z1Controller, 'Z1 %'),
                  _numberInput(_z2Controller, 'Z2 %'),
                  _numberInput(_z3Controller, 'Z3 %'),
                  _numberInput(_z4Controller, 'Z4 %'),
                  _numberInput(_z5Controller, 'Z5 %'),
                  _numberInput(_strideController, 'Stride Threshold'),
                  _numberInput(_windowController, 'Rolling Window Days'),
                  _numberInput(_cmpCadence1Controller, 'Compare A ($compareA)'),
                  _numberInput(_cmpCadence2Controller, 'Compare B ($compareB)'),
                  _numberInput(_cmpCadence3Controller, 'Compare C ($compareC)'),
                  FilledButton.icon(
                    onPressed: _loading ? null : _connectStrava,
                    icon: const Icon(Icons.link),
                    label: const Text('Connect Strava'),
                  ),
                  FilledButton.icon(
                    onPressed: _loading ? null : _fetchFromStravaAndAnalyze,
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('Fetch & Analyze'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        _loading || _samples.isEmpty ? null : _downloadAnalyzedCsv,
                    icon: const Icon(Icons.download),
                    label: const Text('Download CSV'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _reanalyzeCurrentData,
                    icon: const Icon(Icons.tune),
                    label: const Text('Re-analyze Inputs'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _disconnectStrava,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'HR band uses HRR: (HR - Rest HR) / (Max HR - Rest HR). Default zone lower bounds: 59/74/84/88/95 (%). Using Strava client_id from app code. For production web, move client secret to server-side exchange.',
                style: theme.textTheme.bodySmall,
              ),
              if (_status != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(_status!),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              if (_loading) ...<Widget>[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
              if (_result != null) ...<Widget>[
                const SizedBox(height: 22),
                _summaryCard(_result!),
                const SizedBox(height: 18),
                _dataTableCard(),
                const SizedBox(height: 18),
                _chartCard(
                  title: '1) Contamination SD Comparison',
                  subtitle:
                      'Metric = SD of 30-day rolling baseline GAP pace mean (min/km). Each HR band shows 4 bars: with-walk + filtered at $compareA/$compareB/$compareC spm cadence thresholds.',
                  child: SizedBox(
                    height: 340,
                    child: VarianceBarChart(data: _result!.varianceComparison),
                  ),
                ),
                const SizedBox(height: 10),
                _contaminationDetailsCard(_result!),
                const SizedBox(height: 18),
                _chartCard(
                  title: '2) Stride Threshold Sensitivity (120-170 spm)',
                  subtitle:
                      'Blue: normalized baseline SD index (lower raw SD is better). Orange: retained sample %. Current A/B/C: $compareA/$compareB/$compareC spm. log(SD ratio) and bootstrap CI are shown below.',
                  child: SizedBox(
                    height: 340,
                    child: ThresholdSensitivityChart(
                      data: _result!.thresholdSweep,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _thresholdCompareCard(_result!.selectedCadenceComparisons),
                const SizedBox(height: 18),
                _chartCard(
                  title:
                      '3) Dual-Window Trend Example (Current 30d vs Previous 30d)',
                  subtitle:
                      'Bars show baseline GAP pace (mm:ss /km). Positive values indicate a directional shift toward lower baseline pace under fixed HR strata.',
                  child: SizedBox(
                    height: 360,
                    child: DualWindowBarChart(data: _result!.dualWindow),
                  ),
                ),
                const SizedBox(height: 8),
                _dualWindowCompareCard(_result!.dualWindow),
                const SizedBox(height: 8),
                Text(_result!.dualWindowSummary, style: theme.textTheme.titleMedium),
                const SizedBox(height: 24),
              ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberInput(TextEditingController controller, String label) {
    return SizedBox(
      width: 180,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _chartCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(subtitle),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(AnalysisResult result) {
    return Card(
      color: const Color(0xFFEFF8FA),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 18,
          runSpacing: 10,
          children: <Widget>[
            Text('Rows: ${_samples.length}'),
            Text('Runs: ${result.runCount}'),
            Text('Date range: ${result.dateRangeLabel}'),
            Text('Target band for sensitivity: ${result.targetBandLabel}'),
          ],
        ),
      ),
    );
  }

  Widget _thresholdCompareCard(List<SelectedCadenceComparison> rows) {
    return Card(
      color: const Color(0xFFF6FAFD),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Fixed Cadence Comparison',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final SelectedCadenceComparison row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${row.thresholdSpm} spm: SD ${_sdSecPerKmToMinPerKm(row.sdSecPerKm).toStringAsFixed(3)} min/km, SD index ${row.normalizedSdIndex.toStringAsFixed(1)}, retained ${row.retainedPct.toStringAsFixed(1)}%, log(SD ratio)=${row.logSdRatio.isFinite ? row.logSdRatio.toStringAsFixed(3) : 'NA'}, CI=${(row.bootstrapCiLowPct.isFinite && row.bootstrapCiHighPct.isFinite) ? '[${row.bootstrapCiLowPct.toStringAsFixed(1)}%, ${row.bootstrapCiHighPct.toStringAsFixed(1)}%]' : 'NA'}',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _dataTableCard() {
    final List<HRBand> bands = Analyzer._buildBands(<double>[
      _doubleFrom(_z1Controller.text, fallback: 59),
      _doubleFrom(_z2Controller.text, fallback: 74),
      _doubleFrom(_z3Controller.text, fallback: 84),
      _doubleFrom(_z4Controller.text, fallback: 88),
      _doubleFrom(_z5Controller.text, fallback: 95),
    ]);

    final int maxHr = _intFrom(_maxHrController.text, fallback: 200);
    final int restHr = _intFrom(_restHrController.text, fallback: 54);

    final SampleTableSource source = SampleTableSource(
      samples: _samples,
      bandLabelForSample: (RunSample s) {
        final double intensity = _sampleIntensity(
          hr: s.hr,
          maxHr: maxHr,
          restHr: restHr,
        );
        return _bandLabelForIntensity(intensity, bands);
      },
      intensityForSample: (RunSample s) {
        return _sampleIntensity(hr: s.hr, maxHr: maxHr, restHr: restHr);
      },
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'All Data Used To Analyze (${_samples.length} rows)',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Rows are your per-second samples fetched from Strava streams after parsing/cleaning.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double tableWidth = max(constraints.maxWidth, 1040);
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: tableWidth,
                    child: PaginatedDataTable(
                      header: const Text(''),
                      rowsPerPage: _rowsPerPage,
                      availableRowsPerPage: const <int>[10, 20, 50, 100],
                      onRowsPerPageChanged: (int? value) {
                        if (value == null) return;
                        setState(() {
                          _rowsPerPage = value;
                        });
                      },
                      columns: const <DataColumn>[
                        DataColumn(label: Text('run_id')),
                        DataColumn(label: Text('ts')),
                        DataColumn(label: Text('start_time')),
                        DataColumn(label: Text('hr')),
                        DataColumn(label: Text('pace_mm:ss_per_km')),
                        DataColumn(label: Text('cadence_spm')),
                        DataColumn(label: Text('grade_%')),
                        DataColumn(label: Text('intensity')),
                        DataColumn(label: Text('band')),
                      ],
                      source: source,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static double _sampleIntensity({
    required double hr,
    required int maxHr,
    required int restHr,
  }) {
    final int hrrDenominator = maxHr - restHr;
    if (hrrDenominator > 0) {
      final double hrr = (hr - restHr) / hrrDenominator;
      if (hrr.isFinite) return hrr.clamp(0.0, 1.5);
    }
    if (maxHr <= 0) return 0;
    final double pctMax = hr / maxHr;
    if (!pctMax.isFinite) return 0;
    return pctMax.clamp(0.0, 1.5);
  }

  static String _bandLabelForIntensity(double intensity, List<HRBand> bands) {
    if (bands.isEmpty) return '-';
    if (intensity < bands.first.low) return bands.first.label;
    for (final HRBand b in bands) {
      if (intensity >= b.low && intensity < b.high) return b.label;
    }
    return bands.last.label;
  }

  Widget _contaminationDetailsCard(AnalysisResult result) {
    return Card(
      color: const Color(0xFFF6FAFD),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Contamination Reduction Summary',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Reduction % = (with-walk SD - stride-filtered SD) / with-walk SD * 100. This table uses the main Stride Threshold value.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'log(SD ratio) = ln(filtered SD / with-walk SD). Bootstrap CI uses 1,000 resamples on SD reduction%.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const <DataColumn>[
                  DataColumn(label: Text('Band')),
                  DataColumn(label: Text('With-walk SD (min/km)')),
                  DataColumn(label: Text('Filtered SD (min/km)')),
                  DataColumn(label: Text('Reduction %')),
                  DataColumn(label: Text('log(SD ratio)')),
                  DataColumn(label: Text('Bootstrap 95% CI (Reduction %)')),
                ],
                rows: result.varianceComparison
                    .map(
                      (VariancePair v) => DataRow(
                        cells: <DataCell>[
                          DataCell(Text(v.band)),
                          DataCell(
                            Text(
                              _sdSecPerKmToMinPerKm(v.withWalkSdSecPerKm)
                                  .toStringAsFixed(3),
                            ),
                          ),
                          DataCell(
                            Text(
                              _sdSecPerKmToMinPerKm(v.filteredSdSecPerKm)
                                  .toStringAsFixed(3),
                            ),
                          ),
                          DataCell(
                            Text(
                              v.reductionPct.isFinite
                                  ? '${v.reductionPct.toStringAsFixed(1)}%'
                                  : 'NA',
                            ),
                          ),
                          DataCell(
                            Text(
                              v.logSdRatio.isFinite
                                  ? v.logSdRatio.toStringAsFixed(3)
                                  : 'NA',
                            ),
                          ),
                          DataCell(
                            Text(
                              (v.bootstrapCiLowPct.isFinite &&
                                      v.bootstrapCiHighPct.isFinite)
                                  ? '[${v.bootstrapCiLowPct.toStringAsFixed(1)}%, ${v.bootstrapCiHighPct.toStringAsFixed(1)}%]'
                                  : 'NA',
                            ),
                          ),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Average reduction across bands: ${result.varianceReductionAvgPct.isFinite ? result.varianceReductionAvgPct.toStringAsFixed(1) : 'NA'}%',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (result.varianceAnomalyNotes.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                result.varianceAnomalyNotes,
                style: const TextStyle(color: Color(0xFF9A3412)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dualWindowCompareCard(List<DualWindowPoint> rows) {
    return Card(
      color: const Color(0xFFF6FAFD),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('All Zone Comparison (Z1-Z5)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const <DataColumn>[
                  DataColumn(label: Text('Band')),
                  DataColumn(label: Text('Previous 30d')),
                  DataColumn(label: Text('Current 30d')),
                  DataColumn(label: Text('Delta %')),
                ],
                rows: rows
                    .map(
                      (DualWindowPoint p) => DataRow(
                        cells: <DataCell>[
                          DataCell(Text(p.band)),
                          DataCell(Text(_secPerKmToMmssPerKm(p.previousPace))),
                          DataCell(Text(_secPerKmToMmssPerKm(p.currentPace))),
                          DataCell(
                            Text(
                              p.efficiencyDeltaPct.isFinite
                                  ? '${p.efficiencyDeltaPct >= 0 ? '+' : ''}${p.efficiencyDeltaPct.toStringAsFixed(1)}%'
                                  : 'NA',
                            ),
                          ),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StravaAuthService {
  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';

  static const String clientId = 'TODO:<STRAVA_CLIENT_ID>';
  static const String clientSecret = 'TODO:<STRAVA_CLIENT_SECRET>';
  static const String scope = 'TODO:<STRAVA_SCOPE>';

  static Uri buildAuthorizeUri({required String redirectUri}) {
    return Uri.https('www.strava.com', '/oauth/authorize', <String, String>{
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'approval_prompt': 'auto',
      'scope': scope,
    });
  }

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_accessTokenKey, accessToken);
    await sp.setString(_refreshTokenKey, refreshToken);
  }

  Future<String?> getAccessToken() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    return sp.getString(_accessTokenKey);
  }

  Future<String?> getRefreshToken() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    return sp.getString(_refreshTokenKey);
  }

  Future<void> clearTokens() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.remove(_accessTokenKey);
    await sp.remove(_refreshTokenKey);
  }

  Future<void> exchangeCodeForTokens({
    required String code,
    required String redirectUri,
  }) async {
    final http.Response response = await http.post(
      Uri.parse('https://www.strava.com/oauth/token'),
      body: <String, String>{
        'client_id': clientId,
        'client_secret': clientSecret,
        'code': code,
        'grant_type': 'authorization_code',
        'redirect_uri': redirectUri,
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Token exchange failed (${response.statusCode}): ${response.body}',
      );
    }

    final Map<String, dynamic> data = Map<String, dynamic>.from(
      jsonDecode(response.body) as Map,
    );
    final String? accessToken = data['access_token']?.toString();
    final String? refreshToken = data['refresh_token']?.toString();
    if (accessToken == null || refreshToken == null) {
      throw Exception('Strava token response missing access/refresh token.');
    }

    await saveTokens(accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<String?> refreshAccessToken() async {
    final String? refreshToken = await getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      return null;
    }

    final http.Response response = await http.post(
      Uri.parse('https://www.strava.com/api/v3/oauth/token'),
      body: <String, String>{
        'client_id': clientId,
        'client_secret': clientSecret,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );

    if (response.statusCode != 200) return null;

    final Map<String, dynamic> data = Map<String, dynamic>.from(
      jsonDecode(response.body) as Map,
    );
    final String? accessToken = data['access_token']?.toString();
    final String? newRefreshToken = data['refresh_token']?.toString();
    if (accessToken == null || newRefreshToken == null) return null;

    await saveTokens(accessToken: accessToken, refreshToken: newRefreshToken);
    return accessToken;
  }
}

class StravaApiClient {
  StravaApiClient(this._auth);

  final StravaAuthService _auth;

  Future<List<Map<String, dynamic>>> fetchRunActivities() async {
    final String? savedToken = await _auth.getAccessToken();
    if (savedToken == null || savedToken.isEmpty) {
      throw Exception('No Strava access token available.');
    }
    String token = savedToken;

    const int perPage = 200;
    int page = 1;
    final List<Map<String, dynamic>> fetched = <Map<String, dynamic>>[];
    final int afterEpoch =
        DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 122))
            .millisecondsSinceEpoch ~/
        1000;

    while (true) {
      final Uri uri = Uri.https(
        'www.strava.com',
        '/api/v3/athlete/activities',
        <String, String>{
          'per_page': '$perPage',
          'page': '$page',
          'after': '$afterEpoch',
        },
      );

      http.Response response = await _authorizedGet(uri, token);
      if (response.statusCode == 401) {
        final String? next = await _auth.refreshAccessToken();
        if (next == null) break;
        token = next;
        response = await _authorizedGet(uri, token);
      }

      if (response.statusCode != 200) {
        throw Exception(
          'Strava activities fetch failed: ${response.statusCode}',
        );
      }

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw Exception('Unexpected Strava activities response format.');
      }

      if (decoded.isEmpty) break;
      fetched.addAll(
        decoded
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .where((Map<String, dynamic> a) {
              final String t = (a['type'] ?? a['sport_type'] ?? '')
                  .toString()
                  .toLowerCase();
              return t.contains('run');
            }),
      );

      if (decoded.length < perPage) break;
      page += 1;
      if (page > 50) break;
    }

    return fetched;
  }

  Future<Map<String, dynamic>?> fetchActivityStreams(String activityId) async {
    String? token = await _auth.getAccessToken();
    if (token == null || token.isEmpty) return null;

    final Uri uri = Uri.https(
      'www.strava.com',
      '/api/v3/activities/$activityId/streams',
      <String, String>{
        'keys': 'time,heartrate,velocity_smooth,cadence,grade_smooth',
        'key_by_type': 'true',
      },
    );

    http.Response response = await _authorizedGet(uri, token);
    if (response.statusCode == 401) {
      final String? next = await _auth.refreshAccessToken();
      if (next == null) return null;
      token = next;
      response = await _authorizedGet(uri, token);
    }

    if (response.statusCode != 200) return null;

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return null;
  }

  Future<http.Response> _authorizedGet(Uri uri, String token) {
    return http.get(
      uri,
      headers: <String, String>{
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
  }
}

class RunSample {
  RunSample({
    required this.runId,
    required this.ts,
    required this.startTime,
    required this.hr,
    required this.paceSecPerKm,
    required this.cadence,
    this.grade,
  });

  final String runId;
  final DateTime ts;
  final DateTime startTime;
  final double hr;
  final double paceSecPerKm;
  final double cadence;
  final double? grade;
}

class Analyzer {
  Analyzer({
    required this.samples,
    required this.strideThreshold,
    required this.maxHr,
    required this.restHr,
    required this.bandLowerPercents,
    required this.compareCadenceThresholds,
    required this.windowDays,
  }) : bands = _buildBands(bandLowerPercents);

  final List<RunSample> samples;
  final int strideThreshold;
  final int maxHr;
  final int restHr;
  final List<double> bandLowerPercents;
  final List<int> compareCadenceThresholds;
  final int windowDays;
  final List<HRBand> bands;

  AnalysisResult run() {
    if (samples.isEmpty) {
      throw Exception('No samples to analyze.');
    }

    final Set<String> runIds = samples.map((RunSample e) => e.runId).toSet();
    final DateTime minDay = _day(samples.first.startTime);
    final DateTime maxDay = _day(samples.last.startTime);

    final List<DateTime> days = <DateTime>[];
    DateTime cur = minDay;
    while (!cur.isAfter(maxDay)) {
      days.add(cur);
      cur = cur.add(const Duration(days: 1));
    }

    final Map<String, List<RunSample>> byBand = <String, List<RunSample>>{};
    for (final HRBand b in bands) {
      byBand[b.label] = <RunSample>[];
    }

    for (final RunSample s in samples) {
      final HRBand band = _bandOf(_hrBandIntensity(s.hr));
      byBand[band.label]!.add(s);
    }

    final List<int> compareThresholds = compareCadenceThresholds.toSet().toList()
      ..sort();
    final List<VariancePair> variance = <VariancePair>[];
    for (final HRBand b in bands) {
      final List<RollingPoint> withWalkSeries = _rollingBaseline(
        series: byBand[b.label]!,
        days: days,
        strideOnly: false,
        threshold: strideThreshold,
      );
      final List<double> withWalkValues = withWalkSeries
          .map((RollingPoint e) => e.value)
          .toList();
      final Map<int, double> filteredVariances = <int, double>{};
      for (final int threshold in compareThresholds) {
        final List<RollingPoint> filteredSeries = _rollingBaseline(
          series: byBand[b.label]!,
          days: days,
          strideOnly: true,
          threshold: threshold,
        );
        filteredVariances[threshold] = _variance(
          filteredSeries.map((RollingPoint e) => e.value).toList(),
        );
      }
      final List<RollingPoint> primaryFilteredSeries = _rollingBaseline(
        series: byBand[b.label]!,
        days: days,
        strideOnly: true,
        threshold: strideThreshold,
      );
      final List<double> filteredValues = primaryFilteredSeries
          .map((RollingPoint e) => e.value)
          .toList();
      final double primaryFilteredVariance = _variance(
        filteredValues,
      );
      final _CiInterval ci = _bootstrapSdReductionCi(
        withWalkValues,
        filteredValues,
      );
      final double logSdRatio = _logSdRatio(withWalkValues, filteredValues);

      variance.add(
        VariancePair(
          band: b.label,
          comparisonThresholds: compareThresholds,
          withWalkVariance: _variance(
            withWalkValues,
          ),
          filteredVariance: primaryFilteredVariance,
          filteredVariances: filteredVariances,
          logSdRatio: logSdRatio,
          bootstrapCiLowPct: ci.low,
          bootstrapCiHighPct: ci.high,
        ),
      );
    }

    final List<double> validReductions = variance
        .map((VariancePair v) => v.reductionPct)
        .where((double v) => v.isFinite)
        .toList();
    final double avgReduction = validReductions.isEmpty
        ? double.nan
        : validReductions.reduce((double a, double b) => a + b) /
            validReductions.length;
    final List<String> anomalies = variance
        .where(
          (VariancePair v) => v.reductionPct.isFinite && v.reductionPct < 0,
        )
        .map(
          (VariancePair v) =>
              '${v.band} filtered SD is ${(-v.reductionPct).toStringAsFixed(1)}% higher than with-walk',
        )
        .toList();
    final String anomalyNotes = anomalies.isEmpty
        ? ''
        : 'Anomaly note: ${anomalies.join('; ')}. Possible causes: lower walk contamination in that band, composition shift after filtering, or heteroskedasticity.';

    final String targetBand = 'Z2';
    final List<ThresholdPoint> thresholdSweep = _thresholdSweep(
      source: byBand[targetBand]!,
      days: days,
      from: 120,
      to: 170,
      step: 5,
    );
    final List<SelectedCadenceComparison> selectedComparisons =
        _pickSelectedCadenceComparisons(
          thresholdSweep,
          compareCadenceThresholds,
        );

    final DateTime lastDay = maxDay;
    final DateTime currentStart = lastDay.subtract(
      Duration(days: windowDays - 1),
    );
    final DateTime prevEnd = currentStart.subtract(const Duration(days: 1));
    final DateTime prevStart = prevEnd.subtract(Duration(days: windowDays - 1));

    final List<DualWindowPoint> dual = <DualWindowPoint>[];
    for (final HRBand b in bands) {
      final List<RunSample> filtered = byBand[b.label]!
          .where((RunSample e) => e.cadence >= strideThreshold)
          .toList();

      final List<RunSample> inCurrent = filtered.where((RunSample e) {
        final DateTime d = _day(e.startTime);
        return !d.isBefore(currentStart) && !d.isAfter(lastDay);
      }).toList();

      final List<RunSample> inPrevious = filtered.where((RunSample e) {
        final DateTime d = _day(e.startTime);
        return !d.isBefore(prevStart) && !d.isAfter(prevEnd);
      }).toList();

      final double currentBaseline = _mean(
        inCurrent.map((RunSample e) => e.paceSecPerKm).toList(),
      );
      final double previousBaseline = _mean(
        inPrevious.map((RunSample e) => e.paceSecPerKm).toList(),
      );
      dual.add(
        DualWindowPoint(
          band: b.label,
          currentPace: currentBaseline,
          previousPace: previousBaseline,
        ),
      );
    }

    final List<String> zoneDeltaParts = dual
        .where((DualWindowPoint e) => e.efficiencyDeltaPct.isFinite)
        .map(
          (DualWindowPoint p) =>
              '${p.band} ${p.efficiencyDeltaPct >= 0 ? '+' : ''}${p.efficiencyDeltaPct.toStringAsFixed(1)}%',
        )
        .toList();
    final String summary = zoneDeltaParts.isEmpty
        ? 'Not enough data to compute dual-window delta.'
        : 'All-zone delta: ${zoneDeltaParts.join(' | ')} (positive values indicate a directional shift toward lower baseline pace under fixed HR strata).';

    final String range =
        '${minDay.toIso8601String().split('T').first} to ${maxDay.toIso8601String().split('T').first}';

    return AnalysisResult(
      varianceComparison: variance,
      varianceReductionAvgPct: avgReduction,
      varianceAnomalyNotes: anomalyNotes,
      thresholdSweep: thresholdSweep,
      selectedCadenceComparisons: selectedComparisons,
      dualWindow: dual,
      dualWindowSummary: summary,
      runCount: runIds.length,
      dateRangeLabel: range,
      targetBandLabel: targetBand,
    );
  }

  List<ThresholdPoint> _thresholdSweep({
    required List<RunSample> source,
    required List<DateTime> days,
    required int from,
    required int to,
    required int step,
  }) {
    final List<ThresholdPoint> out = <ThresholdPoint>[];
    final int total = source.length;
    final List<RollingPoint> withWalkSeries = _rollingBaseline(
      series: source,
      days: days,
      strideOnly: false,
      threshold: from,
    );
    final List<double> withWalkValues = withWalkSeries
        .map((RollingPoint e) => e.value)
        .toList();

    for (int threshold = from; threshold <= to; threshold += step) {
      final List<RollingPoint> series = _rollingBaseline(
        series: source,
        days: days,
        strideOnly: true,
        threshold: threshold,
      );
      final List<double> filteredValues = series
          .map((RollingPoint e) => e.value)
          .toList();
      final double varRaw = _variance(filteredValues);
      final double sdRaw = (varRaw.isFinite && varRaw >= 0)
          ? sqrt(varRaw)
          : double.nan;
      final double logSdRatio = _logSdRatio(withWalkValues, filteredValues);
      final _CiInterval ci = _bootstrapSdReductionCi(
        withWalkValues,
        filteredValues,
      );
      final int kept = source
          .where((RunSample e) => e.cadence >= threshold)
          .length;
      final double retainedPct = total == 0 ? double.nan : kept * 100 / total;
      out.add(
        ThresholdPoint(
          threshold: threshold.toDouble(),
          sdSecPerKm: sdRaw,
          retainedPct: retainedPct,
          logSdRatio: logSdRatio,
          bootstrapCiLowPct: ci.low,
          bootstrapCiHighPct: ci.high,
        ),
      );
    }

    final List<double> sds = out
        .map((ThresholdPoint e) => e.sdSecPerKm)
        .where((double e) => e.isFinite)
        .toList();

    final double minSd = sds.isEmpty ? 0 : sds.reduce(min);
    final double maxSd = sds.isEmpty ? 1 : sds.reduce(max);

    for (final ThresholdPoint p in out) {
      p.normalizedSdIndex = (maxSd - minSd).abs() < 1e-9
          ? 50
          : ((p.sdSecPerKm - minSd) / (maxSd - minSd) * 100);
    }

    return out;
  }

  List<SelectedCadenceComparison> _pickSelectedCadenceComparisons(
    List<ThresholdPoint> sweep,
    List<int> requestedThresholds,
  ) {
    final List<int> uniqueSorted = requestedThresholds.toSet().toList()..sort();
    final List<SelectedCadenceComparison> out = <SelectedCadenceComparison>[];
    for (final int threshold in uniqueSorted) {
      ThresholdPoint? hit;
      for (final ThresholdPoint p in sweep) {
        if (p.threshold.toInt() == threshold) {
          hit = p;
          break;
        }
      }
      if (hit == null) continue;
      out.add(
        SelectedCadenceComparison(
          thresholdSpm: threshold,
          sdSecPerKm: hit.sdSecPerKm,
          normalizedSdIndex: hit.normalizedSdIndex,
          retainedPct: hit.retainedPct,
          logSdRatio: hit.logSdRatio,
          bootstrapCiLowPct: hit.bootstrapCiLowPct,
          bootstrapCiHighPct: hit.bootstrapCiHighPct,
        ),
      );
    }
    return out;
  }

  List<RollingPoint> _rollingBaseline({
    required List<RunSample> series,
    required List<DateTime> days,
    required bool strideOnly,
    required int threshold,
  }) {
    final List<RollingPoint> out = <RollingPoint>[];

    for (final DateTime day in days) {
      final DateTime start = day.subtract(Duration(days: windowDays - 1));
      final List<double> values = series
          .where((RunSample e) {
            final DateTime d = _day(e.startTime);
            final bool inWindow = !d.isBefore(start) && !d.isAfter(day);
            final bool passStride = !strideOnly || e.cadence >= threshold;
            return inWindow && passStride;
          })
          .map((RunSample e) => e.paceSecPerKm)
          .toList();

      if (values.length < 20) continue;
      out.add(RollingPoint(day: day, value: _mean(values)));
    }

    return out;
  }

  HRBand _bandOf(double hrPctMax) {
    if (hrPctMax < bands.first.low) return bands.first;
    for (final HRBand b in bands) {
      if (hrPctMax >= b.low && hrPctMax < b.high) return b;
    }
    return bands.last;
  }

  static List<HRBand> _buildBands(List<double> lowerBoundsPercent) {
    final List<double> defaults = <double>[59, 74, 84, 88, 95];
    final List<double> raw = lowerBoundsPercent.length == 5
        ? lowerBoundsPercent
        : defaults;
    final List<double> normalized = raw
        .map((double v) => (v.isFinite ? v : 0).clamp(0.0, 100.0).toDouble())
        .toList()
      ..sort();

    final double z1 = normalized[0] / 100.0;
    final double z2 = normalized[1] / 100.0;
    final double z3 = normalized[2] / 100.0;
    final double z4 = normalized[3] / 100.0;
    final double z5 = normalized[4] / 100.0;

    return <HRBand>[
      HRBand('Z1', z1, z2),
      HRBand('Z2', z2, z3),
      HRBand('Z3', z3, z4),
      HRBand('Z4', z4, z5),
      HRBand('Z5', z5, 10.0),
    ];
  }

  double _hrBandIntensity(double hr) {
    final int hrrDenominator = maxHr - restHr;
    if (hrrDenominator > 0) {
      final double hrr = (hr - restHr) / hrrDenominator;
      if (hrr.isFinite) return hrr.clamp(0.0, 1.5);
    }
    final double pctMax = hr / maxHr;
    if (!pctMax.isFinite) return 0;
    return pctMax.clamp(0.0, 1.5);
  }

  static double _logSdRatio(List<double> withWalk, List<double> filtered) {
    if (withWalk.length < 2 || filtered.length < 2) return double.nan;
    final double sdWithWalk = sqrt(_variance(withWalk));
    final double sdFiltered = sqrt(_variance(filtered));
    if (!sdWithWalk.isFinite || !sdFiltered.isFinite) return double.nan;
    if (sdWithWalk <= 0 || sdFiltered <= 0) return double.nan;
    return log(sdFiltered / sdWithWalk);
  }

  static _CiInterval _bootstrapSdReductionCi(
    List<double> withWalk,
    List<double> filtered, {
    int iterations = 1000,
  }) {
    if (withWalk.length < 3 || filtered.length < 3) {
      return const _CiInterval(low: double.nan, high: double.nan);
    }
    final Random rng = Random(42);
    final List<double> reductions = <double>[];
    for (int i = 0; i < iterations; i++) {
      final List<double> ws = _bootstrapSample(withWalk, rng);
      final List<double> fs = _bootstrapSample(filtered, rng);
      final double sdW = sqrt(_variance(ws));
      final double sdF = sqrt(_variance(fs));
      if (!sdW.isFinite || !sdF.isFinite || sdW <= 0) continue;
      reductions.add((sdW - sdF) / sdW * 100.0);
    }
    if (reductions.isEmpty) {
      return const _CiInterval(low: double.nan, high: double.nan);
    }
    reductions.sort();
    return _CiInterval(
      low: _percentile(reductions, 0.025),
      high: _percentile(reductions, 0.975),
    );
  }

  static List<double> _bootstrapSample(List<double> source, Random rng) {
    final List<double> out = List<double>.filled(source.length, 0);
    for (int i = 0; i < source.length; i++) {
      out[i] = source[rng.nextInt(source.length)];
    }
    return out;
  }

  static double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return double.nan;
    final double pos = (sorted.length - 1) * p;
    final int lower = pos.floor();
    final int upper = pos.ceil();
    if (lower == upper) return sorted[lower];
    final double weight = pos - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
  }

  static DateTime _day(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  static double _mean(List<double> values) {
    if (values.isEmpty) return double.nan;
    return values.reduce((double a, double b) => a + b) / values.length;
  }

  static double _variance(List<double> values) {
    if (values.length < 2) return double.nan;
    final double m = _mean(values);
    double sum = 0;
    for (final double v in values) {
      sum += (v - m) * (v - m);
    }
    return sum / (values.length - 1);
  }
}

class HRBand {
  HRBand(this.label, this.low, this.high);

  final String label;
  final double low;
  final double high;
}

class RollingPoint {
  RollingPoint({required this.day, required this.value});

  final DateTime day;
  final double value;
}

class _CiInterval {
  const _CiInterval({required this.low, required this.high});

  final double low;
  final double high;
}

class VariancePair {
  VariancePair({
    required this.band,
    required this.comparisonThresholds,
    required this.withWalkVariance,
    required this.filteredVariance,
    required this.filteredVariances,
    required this.logSdRatio,
    required this.bootstrapCiLowPct,
    required this.bootstrapCiHighPct,
  });

  final String band;
  final List<int> comparisonThresholds;
  final double withWalkVariance;
  final double filteredVariance;
  final Map<int, double> filteredVariances;
  final double logSdRatio;
  final double bootstrapCiLowPct;
  final double bootstrapCiHighPct;

  double get withWalkSdSecPerKm {
    if (!withWalkVariance.isFinite || withWalkVariance < 0) return double.nan;
    return sqrt(withWalkVariance);
  }

  double get filteredSdSecPerKm {
    if (!filteredVariance.isFinite || filteredVariance < 0) return double.nan;
    return sqrt(filteredVariance);
  }

  double get reductionPct {
    if (!withWalkSdSecPerKm.isFinite || withWalkSdSecPerKm <= 0) {
      return double.nan;
    }
    if (!filteredSdSecPerKm.isFinite) return double.nan;
    return (withWalkSdSecPerKm - filteredSdSecPerKm) / withWalkSdSecPerKm * 100.0;
  }
}

class ThresholdPoint {
  ThresholdPoint({
    required this.threshold,
    required this.sdSecPerKm,
    required this.retainedPct,
    required this.logSdRatio,
    required this.bootstrapCiLowPct,
    required this.bootstrapCiHighPct,
  });

  final double threshold;
  final double sdSecPerKm;
  final double retainedPct;
  final double logSdRatio;
  final double bootstrapCiLowPct;
  final double bootstrapCiHighPct;
  double normalizedSdIndex = 0;
}

class DualWindowPoint {
  DualWindowPoint({
    required this.band,
    required this.currentPace,
    required this.previousPace,
  });

  final String band;
  final double currentPace;
  final double previousPace;

  double get efficiencyDeltaPct {
    if (!currentPace.isFinite || !previousPace.isFinite || previousPace <= 0) {
      return double.nan;
    }
    return (previousPace - currentPace) / previousPace * 100;
  }
}

class AnalysisResult {
  AnalysisResult({
    required this.varianceComparison,
    required this.varianceReductionAvgPct,
    required this.varianceAnomalyNotes,
    required this.thresholdSweep,
    required this.selectedCadenceComparisons,
    required this.dualWindow,
    required this.dualWindowSummary,
    required this.runCount,
    required this.dateRangeLabel,
    required this.targetBandLabel,
  });

  final List<VariancePair> varianceComparison;
  final double varianceReductionAvgPct;
  final String varianceAnomalyNotes;
  final List<ThresholdPoint> thresholdSweep;
  final List<SelectedCadenceComparison> selectedCadenceComparisons;
  final List<DualWindowPoint> dualWindow;
  final String dualWindowSummary;
  final int runCount;
  final String dateRangeLabel;
  final String targetBandLabel;
}

class SelectedCadenceComparison {
  SelectedCadenceComparison({
    required this.thresholdSpm,
    required this.sdSecPerKm,
    required this.normalizedSdIndex,
    required this.retainedPct,
    required this.logSdRatio,
    required this.bootstrapCiLowPct,
    required this.bootstrapCiHighPct,
  });

  final int thresholdSpm;
  final double sdSecPerKm;
  final double normalizedSdIndex;
  final double retainedPct;
  final double logSdRatio;
  final double bootstrapCiLowPct;
  final double bootstrapCiHighPct;
}

class SampleTableSource extends DataTableSource {
  SampleTableSource({
    required this.samples,
    required this.bandLabelForSample,
    required this.intensityForSample,
  });

  final List<RunSample> samples;
  final String Function(RunSample) bandLabelForSample;
  final double Function(RunSample) intensityForSample;

  @override
  DataRow? getRow(int index) {
    if (index < 0 || index >= samples.length) return null;
    final RunSample s = samples[index];
    final double intensity = intensityForSample(s);
    return DataRow.byIndex(
      index: index,
      cells: <DataCell>[
        DataCell(Text(s.runId)),
        DataCell(Text(_fmtDateTime(s.ts))),
        DataCell(Text(_fmtDateTime(s.startTime))),
        DataCell(Text(s.hr.toStringAsFixed(1))),
        DataCell(Text(_secPerKmToMmssPerKm(s.paceSecPerKm))),
        DataCell(Text(s.cadence.toStringAsFixed(1))),
        DataCell(Text(s.grade?.toStringAsFixed(2) ?? '')),
        DataCell(Text(intensity.toStringAsFixed(3))),
        DataCell(Text(bandLabelForSample(s))),
      ],
    );
  }

  @override
  bool get isRowCountApproximate => false;

  @override
  int get rowCount => samples.length;

  @override
  int get selectedRowCount => 0;
}

class VarianceBarChart extends StatelessWidget {
  const VarianceBarChart({super.key, required this.data});

  final List<VariancePair> data;

  @override
  Widget build(BuildContext context) {
    final List<int> thresholds = data.isEmpty
        ? <int>[]
        : data.first.comparisonThresholds;
    final List<BarChartGroupData> groups = <BarChartGroupData>[];
    for (int i = 0; i < data.length; i++) {
      final VariancePair p = data[i];
      final List<BarChartRodData> rods = <BarChartRodData>[
        BarChartRodData(
          toY: p.withWalkSdSecPerKm.isFinite
              ? _sdSecPerKmToMinPerKm(p.withWalkSdSecPerKm)
              : 0,
          color: const Color(0xFFB23A48),
          width: 10,
          borderRadius: BorderRadius.circular(2),
        ),
      ];
      final List<Color> filteredColors = <Color>[
        const Color(0xFF2A9D8F),
        const Color(0xFF1D6FA3),
        const Color(0xFFE9C46A),
      ];
      for (int tIdx = 0; tIdx < thresholds.length; tIdx++) {
        final int threshold = thresholds[tIdx];
        final double v = p.filteredVariances[threshold] ?? double.nan;
        final double sdSec = (v.isFinite && v >= 0) ? sqrt(v) : double.nan;
        rods.add(
          BarChartRodData(
            toY: sdSec.isFinite ? _sdSecPerKmToMinPerKm(sdSec) : 0,
            color: filteredColors[tIdx % filteredColors.length],
            width: 10,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }
      groups.add(
        BarChartGroupData(
          x: i,
          barsSpace: 3,
          barRods: rods,
        ),
      );
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: BarChart(
            BarChartData(
              barGroups: groups,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    getTitlesWidget: (double value, TitleMeta meta) => Text(
                      value.toStringAsFixed(2),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (double value, TitleMeta meta) {
                      final int idx = value.toInt();
                      if (idx < 0 || idx >= data.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(data[idx].band),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          children: <Widget>[
            const _LegendDot(color: Color(0xFFB23A48), label: 'With walk'),
            for (int i = 0; i < thresholds.length; i++)
              _LegendDot(
                color: <Color>[
                  const Color(0xFF2A9D8F),
                  const Color(0xFF1D6FA3),
                  const Color(0xFFE9C46A),
                ][i % 3],
                label: 'Filtered ${thresholds[i]} spm',
              ),
          ],
        ),
      ],
    );
  }
}

class ThresholdSensitivityChart extends StatelessWidget {
  const ThresholdSensitivityChart({super.key, required this.data});

  final List<ThresholdPoint> data;

  @override
  Widget build(BuildContext context) {
    final List<FlSpot> sdIndex = <FlSpot>[];
    final List<FlSpot> retained = <FlSpot>[];

    for (final ThresholdPoint p in data) {
      if (p.normalizedSdIndex.isFinite) {
        sdIndex.add(FlSpot(p.threshold, p.normalizedSdIndex));
      }
      if (p.retainedPct.isFinite) {
        retained.add(FlSpot(p.threshold, p.retainedPct));
      }
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: LineChart(
            LineChartData(
              minX: 118,
              maxX: 172,
              minY: 0,
              maxY: 100,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                bottomTitles: AxisTitles(
                  axisNameWidget: const Text('Stride threshold (spm)'),
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 10,
                    getTitlesWidget: (double value, TitleMeta meta) => Text(
                      value.toInt().toString(),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
                leftTitles: AxisTitles(
                  axisNameWidget: const Text('Index / %'),
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 20,
                    reservedSize: 34,
                    getTitlesWidget: (double value, TitleMeta meta) => Text(
                      value.toInt().toString(),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ),
              lineBarsData: <LineChartBarData>[
                LineChartBarData(
                  spots: sdIndex,
                  color: const Color(0xFF1D6FA3),
                  barWidth: 2.5,
                  dotData: const FlDotData(show: false),
                ),
                LineChartBarData(
                  spots: retained,
                  color: const Color(0xFFE76F51),
                  barWidth: 2.5,
                  dotData: const FlDotData(show: false),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Wrap(
          spacing: 14,
          children: <Widget>[
            _LegendDot(
              color: Color(0xFF1D6FA3),
              label: 'Normalized SD index',
            ),
            _LegendDot(color: Color(0xFFE76F51), label: 'Retained sample %'),
          ],
        ),
      ],
    );
  }
}

class DualWindowBarChart extends StatelessWidget {
  const DualWindowBarChart({super.key, required this.data});

  final List<DualWindowPoint> data;

  @override
  Widget build(BuildContext context) {
    final List<BarChartGroupData> groups = <BarChartGroupData>[];
    for (int i = 0; i < data.length; i++) {
      final DualWindowPoint p = data[i];
      groups.add(
            BarChartGroupData(
              x: i,
              barsSpace: 4,
              barRods: <BarChartRodData>[
            BarChartRodData(
              toY: p.previousPace.isFinite
                  ? _secPerKmToMinPerKm(p.previousPace)
                  : 0,
              color: const Color(0xFFB23A48),
              width: 14,
              borderRadius: BorderRadius.circular(2),
            ),
            BarChartRodData(
              toY: p.currentPace.isFinite
                  ? _secPerKmToMinPerKm(p.currentPace)
                  : 0,
              color: const Color(0xFF2A9D8F),
              width: 14,
              borderRadius: BorderRadius.circular(2),
            ),
          ],
        ),
      );
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: BarChart(
            BarChartData(
              barGroups: groups,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  axisNameWidget: const Text('Pace (mm:ss /km)'),
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    getTitlesWidget: (double value, TitleMeta meta) => Text(
                      _minPerKmToMmssPerKm(value),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (double value, TitleMeta meta) {
                      final int idx = value.toInt();
                      if (idx < 0 || idx >= data.length) {
                        return const SizedBox.shrink();
                      }
                      final double delta = data[idx].efficiencyDeltaPct;
                      final String deltaLabel = delta.isFinite
                          ? '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}%'
                          : 'NA';
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${data[idx].band}\n$deltaLabel',
                          textAlign: TextAlign.center,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Wrap(
          spacing: 14,
          children: <Widget>[
            _LegendDot(color: Color(0xFFB23A48), label: 'Previous 30d'),
            _LegendDot(color: Color(0xFF2A9D8F), label: 'Current 30d'),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}

int _intFrom(String raw, {required int fallback}) {
  return int.tryParse(raw.trim()) ?? fallback;
}

double _doubleFrom(String raw, {required double fallback}) {
  return double.tryParse(raw.trim()) ?? fallback;
}

DateTime? _parseDateTime(String? raw) {
  if (raw == null) return null;
  return DateTime.tryParse(raw);
}

List<double> _extractStreamSeries(Map<String, dynamic> streams, String key) {
  final dynamic data = streams[key]?['data'];
  if (data is! List) return const <double>[];
  return data.whereType<num>().map((num e) => e.toDouble()).toList();
}

String _fmtDateTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

String _csvCell(String value) {
  final String escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}

double _secPerKmToMinPerKm(double secPerKm) => secPerKm / 60.0;

double _sdSecPerKmToMinPerKm(double sdSecPerKm) => sdSecPerKm / 60.0;

String _secPerKmToMmssPerKm(double secPerKm) {
  if (!secPerKm.isFinite || secPerKm <= 0) return '-';
  final int totalSec = secPerKm.round();
  final int minPart = totalSec ~/ 60;
  final int secPart = totalSec % 60;
  return '$minPart:${secPart.toString().padLeft(2, '0')} /km';
}

String _minPerKmToMmssPerKm(double minPerKm) {
  if (!minPerKm.isFinite || minPerKm <= 0) return '-';
  return _secPerKmToMmssPerKm(minPerKm * 60);
}
