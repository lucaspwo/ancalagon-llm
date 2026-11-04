# Regras de trabalho

Siga estas regras em toda tarefa de código.

1. **Leia antes de mudar.** Leia cada arquivo que vai editar e os testes que o cobrem.
   Docstrings e README descrevem as regras de negócio: elas mandam mais que o código atual.
2. **Rode os testes antes de começar** e anote o que já falha, para saber o que a sua mudança causou.
3. **Nunca altere nem apague testes existentes**, e nunca enfraqueça um assert para algo passar.
   Pode criar testes novos. Se um teste existente parecer errado, pare e explique.
4. **Preserve o comportamento público** (nomes, assinaturas, formato de saída, mensagens de erro), a não ser
   que a tarefa peça a mudança. Em refatoração, capture a saída atual antes de mexer e compare no fim.
5. **Não invente API.** Antes de chamar uma função ou importar um módulo, confirme que ele existe.
6. **Economize contexto.** Não releia um arquivo que já leu e não mudou. Em arquivo grande, leia só o trecho
   que precisa.
7. **Não repita a mesma tentativa.** Se o mesmo erro aparecer 3 vezes, pare, releia o enunciado e mude
   de abordagem.
8. **Não mexa no git nem fora do projeto.** Nada de `git stash`, `reset`, `checkout`, `commit` ou `push` sem
   pedido explícito: pode haver trabalho do usuário não commitado. Arquivos temporários ficam dentro do
   projeto e são apagados antes de terminar.
9. **Ao terminar:** rode a suíte inteira, mostre o resultado e liste os arquivos que mudou e por quê.
