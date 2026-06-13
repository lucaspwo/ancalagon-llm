# Console TTY (fonte e p10k)

Setup do console framebuffer do kernel no Ancalagon-Ubuntu (sem display manager,
boot termina em `tty1` com login direto). Aplicável quando se está fisicamente
à frente da máquina — acesso normal continua via SSH.

## Estado configurado

| Item | Valor | Por quê |
|---|---|---|
| `FONTFACE` | `TerminusBold` | Glyph set Latin completo, peso bold tem boa legibilidade no framebuffer |
| `FONTSIZE` | `16x32` | Tamanho confortável em 1080p à distância normal de teclado; legível também em 4K |
| `CODESET` | `Lat15` | Cobre Latin-1 + Latin-9 (acentos pt-BR íntegros); determinístico vs `guess` |
| `ACTIVE_CONSOLES` | `/dev/tty[1-6]` | Padrão Ubuntu, mantido |

Default original do Ubuntu Server 24.04 era `Fixed 8x16` com `CODESET=guess` —
fonte VGA de 8 pixels de largura, ilegível em 1080p+ a distância de teclado.

## Decisões

- **Console TTY em vez de emulador gráfico.** Ancalagon é servidor LLM dedicado
  — quando llama.cpp carrega um Q4 de 27-32B, VRAM da 4070 Ti SUPER fica próxima
  do limite. X server competindo pela mesma GPU pode causar OOM no driver
  durante inferência massiva. Acesso "à frente" é eventual; TTY tem zero
  conflito de VRAM.
- **TerminusBold em vez de Terminus regular.** Bold pesa mais no framebuffer
  e melhora contraste em monitores com brilho médio.
- **`Lat15` em vez de `guess`.** `guess` deduz pelo locale; em ambiente headless
  isso pode variar por sessão. Lat15 é explícito e cobre todos os caracteres
  necessários para pt-BR.
- **Não instalar Nerd Font no console.** PSF tem teto de 512 glyphs — Nerd
  Fonts (~3500 glyphs) não cabem. Para visual completo no console, alternativa
  futura seria substituir o console do kernel por `kmscon` (renderiza TTF via
  OpenGL). Não vale a pena para uso eventual.

## Aplicação

```bash
# No Ancalagon, com setup-system.sh:
make install-system   # do Mac, ou:
bash scripts/setup-system.sh

# Ou manualmente (para mudar tamanho rapidamente):
sudo cp systemd/console-setup /etc/default/console-setup
sudo setupcon --save --force
sudo update-initramfs -u    # para fonte aparecer cedo no boot
```

`setupcon` aplica imediatamente nos TTYs definidos em `ACTIVE_CONSOLES`.
`update-initramfs` é necessário se quiser a fonte ativa antes do systemd
montar `/usr` (raramente importa para login interativo, mas evita flash de
fonte velha durante boot).

## Tamanhos disponíveis (TerminusBold)

`8x14, 8x16, 10x18, 10x20, 11x22, 12x24, 14x28, 16x32` — listados em
`/usr/share/consolefonts/` como `*-Terminus*Bold*.psf.gz`.

Em 1080p, `16x32` ≈ 120 col × 33 linhas. Se quiser mais densidade:
`14x28` ≈ 137 col × 38, `12x24` ≈ 160 col × 45.

## Powerlevel10k em TTY

`TERM=linux` no console não tem Nerd Font → glyphs do p10k aparecem como
retângulos. Snippet aplicado em `~/.zshrc` do Ancalagon (manual, não
gerenciado por este repo porque é arquivo de usuário):

```zsh
# inserir antes de `source $ZSH/oh-my-zsh.sh`:
[[ $TERM == linux ]] && POWERLEVEL9K_MODE=ascii && POWERLEVEL9K_INSTANT_PROMPT=quiet
```

`MODE=ascii` cai num estilo simplificado (◆, §, ~) que existe no PSF.
Em SSH (`TERM=xterm-256color`) o guard fica inativo e o p10k volta ao modo
`nerdfont-v3` normal.

## Ferramentas

- `console-setup(5)` — manual da configuração
- `setupcon(8)` — aplica `/etc/default/console-setup`
- `consolefonts` — lista em `/usr/share/consolefonts/`
- `showconsolefont` — mostra grade de glyphs da fonte ativa (útil para validar
  que acentos e símbolos básicos estão presentes)
