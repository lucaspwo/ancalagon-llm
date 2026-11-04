# Regras de trabalho neste repositório

Siga estas regras em toda tarefa de código. Elas existem para evitar erros comuns.

1. **Leia antes de mudar.** Leia por inteiro cada arquivo que vai editar, e os testes que o cobrem.
   Docstrings e README descrevem as regras de negócio: elas mandam mais que o código atual.
2. **Rode os testes antes de começar** e anote o que já falha. Assim você sabe o que a sua mudança causou.
3. **Uma mudança por vez.** Faça uma edição pequena, rode os testes, depois a próxima.
4. **Nunca altere nem apague testes existentes**, e nunca enfraqueça um assert para algo passar.
   Pode criar testes novos. Se um teste existente parecer errado, pare e explique em vez de mexer nele.
5. **Preserve o comportamento público** (nomes, assinaturas, formato de saída, mensagens de erro),
   a não ser que a tarefa peça a mudança. Em refatoração, a saída tem que continuar idêntica.
6. **Não invente API.** Antes de chamar uma função ou importar um módulo, confirme que existe (leia ou busque).
7. **Não repita a mesma tentativa.** Se o mesmo erro aparecer 3 vezes, pare, releia o código e o enunciado,
   e mude de abordagem.
8. **Ao terminar:** rode a suíte inteira, mostre o resultado, e liste os arquivos que mudou e por quê.
   Não deixe prints de depuração nem arquivos temporários.
