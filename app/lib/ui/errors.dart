/// What an error from a command or a transfer means, in words for the user. The names are the hub's
/// (SPEC.md, section 5) and the players' own; anything else shows as it came.
String describeError(String? error) => switch (error) {
  'no such track' => 'Não há próxima faixa.',
  'nothing playable' => 'Nada nessa fila pode tocar aqui.',
  'offline' => 'O aparelho está desligado.',
  'timeout' => 'O aparelho não respondeu.',
  'unsupported' => 'O aparelho não aceita esse comando.',
  'notPlayer' => 'Esse aparelho não toca música.',
  'unknownDevice' => 'O aparelho não está mais na lista.',
  'nothingToTransfer' => 'Não há nada tocando lá.',
  'closed' => 'Sem conexão com o hub.',
  null => 'Algo deu errado.',
  _ => error,
};
