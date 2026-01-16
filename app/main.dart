import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

void main() => runApp(const CaixaApp());

class CaixaApp extends StatelessWidget {
  const CaixaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Caixa Simples',
      theme: ThemeData(useMaterial3: true),
      home: const CaixaHomePage(),
    );
  }
}

enum FiltroModo { tudo, hoje, mes }

class Lancamento {
  final String id;
  final String data; // YYYY-MM-DD
  final String tipo; // "Entrada" | "Saída"
  final double valor;
  final String categoria;
  final String descricao;

  Lancamento({
    required this.id,
    required this.data,
    required this.tipo,
    required this.valor,
    required this.categoria,
    required this.descricao,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'data': data,
        'tipo': tipo,
        'valor': valor,
        'categoria': categoria,
        'descricao': descricao,
      };

  static Lancamento fromJson(Map<String, dynamic> j) {
    return Lancamento(
      id: (j['id'] ?? _newId()).toString(),
      data: (j['data'] ?? _todayStr()).toString(),
      tipo: (j['tipo'] ?? 'Entrada').toString(),
      valor: (j['valor'] is num) ? (j['valor'] as num).toDouble() : double.tryParse('${j['valor']}') ?? 0.0,
      categoria: (j['categoria'] ?? 'Geral').toString(),
      descricao: (j['descricao'] ?? '').toString(),
    );
  }
}

String _todayStr() => DateFormat('yyyy-MM-dd').format(DateTime.now());

String _newId() {
  final now = DateTime.now();
  return DateFormat('yyyyMMddHHmmssSSS').format(now);
}

double moneyToDouble(String input) {
  var txt = input.trim();
  if (txt.isEmpty) return 0.0;

  // Aceita 1.234,56 (BR) e 1234.56 (EN)
  final hasComma = txt.contains(',');
  final hasDot = txt.contains('.');
  if (hasComma && hasDot) {
    // padrão BR: remove pontos e troca vírgula por ponto
    txt = txt.replaceAll('.', '').replaceAll(',', '.');
  } else {
    // troca vírgula por ponto se houver
    txt = txt.replaceAll(',', '.');
  }
  return double.parse(txt);
}

String fmtMoney(double v) {
  // Formato BR simples
  final f = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
  return f.format(v);
}

class CaixaHomePage extends StatefulWidget {
  const CaixaHomePage({super.key});

  @override
  State<CaixaHomePage> createState() => _CaixaHomePageState();
}

class _CaixaHomePageState extends State<CaixaHomePage> {
  static const dataFileName = 'caixa_dados.json';
  static const csvFileName = 'caixa_export.csv';

  final List<Lancamento> _lancamentos = [];
  FiltroModo _filtro = FiltroModo.tudo;
  final TextEditingController _buscaCtrl = TextEditingController();

  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    _loadData();
    _buscaCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _buscaCtrl.dispose();
    super.dispose();
  }

  Future<File> _dataFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$dataFileName');
  }

  Future<File> _csvFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$csvFileName');
  }

  Future<void> _loadData() async {
    try {
      final f = await _dataFile();
      if (await f.exists()) {
        final txt = await f.readAsString(encoding: utf8);
        final decoded = json.decode(txt);
        if (decoded is List) {
          final list = decoded
              .whereType<Map>()
              .map((m) => Lancamento.fromJson(Map<String, dynamic>.from(m)))
              .toList();

          // ordenar: mais recente primeiro (data desc + id desc)
          list.sort((a, b) {
            final c1 = b.data.compareTo(a.data);
            if (c1 != 0) return c1;
            return b.id.compareTo(a.id);
          });

          _lancamentos
            ..clear()
            ..addAll(list);
        }
      }
    } catch (_) {
      // se falhar, inicia vazio
    } finally {
      setState(() => _carregando = false);
    }
  }

  Future<void> _saveData() async {
    try {
      final f = await _dataFile();
      final txt = json.encode(_lancamentos.map((e) => e.toJson()).toList());
      await f.writeAsString(txt, encoding: utf8);
    } catch (e) {
      _toast('Falha ao salvar: $e');
    }
  }

  Iterable<Lancamento> _iterFiltered() sync* {
    final q = _buscaCtrl.text.trim().toLowerCase();
    final today = _todayStr();
    final month = DateFormat('yyyy-MM').format(DateTime.now());

    for (final it in _lancamentos) {
      if (_filtro == FiltroModo.hoje && it.data != today) continue;
      if (_filtro == FiltroModo.mes && !it.data.startsWith(month)) continue;

      if (q.isNotEmpty) {
        final cat = it.categoria.toLowerCase();
        final desc = it.descricao.toLowerCase();
        if (!cat.contains(q) && !desc.contains(q)) continue;
      }
      yield it;
    }
  }

  (double saldo, double entradas, double saidas) _computeTotals() {
    double entradas = 0.0;
    double saidas = 0.0;

    for (final it in _iterFiltered()) {
      if (it.tipo == 'Entrada') {
        entradas += it.valor;
      } else {
        saidas += it.valor;
      }
    }
    final saldo = entradas - saidas;
    return (saldo, entradas, saidas);
  }

  Future<void> _addLancamentoDialog(String tipoDefault) async {
    final dataCtrl = TextEditingController(text: _todayStr());
    final valorCtrl = TextEditingController();
    final catCtrl = TextEditingController(text: 'Geral');
    final descCtrl = TextEditingController();
    String tipo = tipoDefault;

    Future<void> salvar() async {
      try {
        final data = dataCtrl.text.trim();
        DateFormat('yyyy-MM-dd').parseStrict(data);

        final valor = moneyToDouble(valorCtrl.text);
        if (valor <= 0) {
          _toast('Valor deve ser maior que zero.');
          return;
        }

        final item = Lancamento(
          id: _newId(),
          data: data,
          tipo: tipo,
          valor: valor,
          categoria: catCtrl.text.trim().isEmpty ? 'Geral' : catCtrl.text.trim(),
          descricao: descCtrl.text.trim(),
        );

        setState(() {
          _lancamentos.insert(0, item);
        });
        await _saveData();
        if (mounted) Navigator.pop(context);
      } catch (_) {
        _toast('Data inválida. Use YYYY-MM-DD (ex: 2026-01-15).');
      }
    }

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Novo lançamento'),
          content: SingleChildScrollView(
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  value: tipo,
                  items: const [
                    DropdownMenuItem(value: 'Entrada', child: Text('Entrada')),
                    DropdownMenuItem(value: 'Saída', child: Text('Saída')),
                  ],
                  onChanged: (v) => tipo = v ?? tipoDefault,
                  decoration: const InputDecoration(labelText: 'Tipo'),
                ),
                TextField(
                  controller: dataCtrl,
                  decoration: const InputDecoration(labelText: 'Data (YYYY-MM-DD)'),
                ),
                TextField(
                  controller: valorCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Valor (ex: 10,50)'),
                ),
                TextField(
                  controller: catCtrl,
                  decoration: const InputDecoration(labelText: 'Categoria'),
                ),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(labelText: 'Descrição (opcional)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: salvar, child: const Text('Salvar')),
          ],
        );
      },
    );
  }

  Future<void> _confirmDelete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmação'),
        content: const Text('Excluir este lançamento?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir')),
        ],
      ),
    );

    if (ok == true) {
      setState(() {
        _lancamentos.removeWhere((e) => e.id == id);
      });
      await _saveData();
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmação'),
        content: const Text('Apagar TODOS os lançamentos? Esta ação não pode ser desfeita.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar tudo')),
        ],
      ),
    );

    if (ok == true) {
      setState(() => _lancamentos.clear());
      await _saveData();
    }
  }

  Future<void> _exportCsv() async {
    try {
      final rows = <List<dynamic>>[
        ['data', 'tipo', 'valor', 'categoria', 'descricao', 'id'],
        ..._lancamentos.map((it) => [
              it.data,
              it.tipo,
              it.valor.toStringAsFixed(2).replaceAll('.', ','),
              it.categoria,
              it.descricao,
              it.id,
            ]),
      ];

      final csv = const ListToCsvConverter(fieldDelimiter: ';').convert(rows);
      final f = await _csvFile();
      await f.writeAsString(csv, encoding: utf8);

      _toast('CSV exportado em: ${f.path}');
    } catch (e) {
      _toast('Falha ao exportar CSV: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final (saldo, entradas, saidas) = _computeTotals();
    final itens = _iterFiltered().toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Caixa Simples'),
        actions: [
          IconButton(
            tooltip: 'Exportar CSV',
            onPressed: _exportCsv,
            icon: const Icon(Icons.download),
          ),
          IconButton(
            tooltip: 'Limpar tudo',
            onPressed: _confirmClear,
            icon: const Icon(Icons.delete_forever),
          ),
        ],
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Saldo: ${fmtMoney(saldo)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Text('Entradas: ${fmtMoney(entradas)}', style: const TextStyle(fontSize: 16)),
                          Text('Saídas: ${fmtMoney(saidas)}', style: const TextStyle(fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      DropdownButton<FiltroModo>(
                        value: _filtro,
                        items: const [
                          DropdownMenuItem(value: FiltroModo.tudo, child: Text('Tudo')),
                          DropdownMenuItem(value: FiltroModo.hoje, child: Text('Hoje')),
                          DropdownMenuItem(value: FiltroModo.mes, child: Text('Mês')),
                        ],
                        onChanged: (v) => setState(() => _filtro = v ?? FiltroModo.tudo),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _buscaCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Buscar (categoria/descrição)',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: itens.isEmpty
                        ? const Center(child: Text('Nenhum lançamento encontrado.'))
                        : ListView.builder(
                            itemCount: itens.length,
                            itemBuilder: (ctx, i) {
                              final it = itens[i];
                              return Card(
                                child: ListTile(
                                  title: Text('${it.data} • ${it.tipo}'),
                                  subtitle: Text('Categoria: ${it.categoria}\n${it.descricao.isEmpty ? '—' : it.descricao}'),
                                  isThreeLine: true,
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(fmtMoney(it.valor), style: const TextStyle(fontWeight: FontWeight.bold)),
                                      const SizedBox(height: 6),
                                      InkWell(
                                        onTap: () => _confirmDelete(it.id),
                                        child: const Icon(Icons.delete, size: 18),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'entrada',
            onPressed: () => _addLancamentoDialog('Entrada'),
            icon: const Icon(Icons.add),
            label: const Text('Entrada'),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'saida',
            onPressed: () => _addLancamentoDialog('Saída'),
            icon: const Icon(Icons.remove),
            label: const Text('Saída'),
          ),
        ],
      ),
    );
  }
}
