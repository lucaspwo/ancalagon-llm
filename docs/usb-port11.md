# USB port11 morta — erro -71 em loop

## Sintoma

A cada boot e a cada resume, o console e o `dmesg` do Ancalagon recebem rajadas de:

```
usb usb3-port11: Cannot enable. Maybe the USB cable is bad?
usb 3-11: device descriptor read/64, error -71
usb 3-11: Device not responding to setup address.
usb 3-11: device not accepting address <N>, error -71
usb usb3-port11: attempt power cycle
usb usb3-port11: unable to enumerate USB device
```

`error -71` é `EPROTO` — erro de protocolo no barramento.

## Diagnóstico

| Fato | Como foi verificado |
|---|---|
| Sempre a **mesma** porta | 115+ ocorrências, todas em `usb3-port11`; nenhuma outra porta |
| O dispositivo **nunca** enumera | `journalctl \| grep -c "usb 3-11: New USB device found"` = **0** |
| É **low-speed** (1,5 Mbit/s) | HID: teclado/mouse/receptor/controlador. Nunca storage |
| Não é sobrecorrente | `over_current_count` = 0 |
| Não é driver do Linux | O sintoma aparece no Windows também |
| Nada funcional depende da porta | Desabilitar não remove nenhum device do barramento |
| Começou em **18/ago/2026** | Journal cobre desde 30/jul (27 boots) com **zero** ocorrências antes |

18/ago é o dia em que o gabinete foi aberto para remover o NV3 defeituoso. A hipótese principal é
que **um header USB interno ficou mal assentado** nessa intervenção; a alternativa é a própria
porta com defeito elétrico (um pino em curto faz o hub detectar "algo" e falhar a negociação, sem
nada plugado).

Como o dispositivo nunca completa a enumeração, **não há VID/PID** — nem o kernel sabe o que é.
Identificação por software está descartada; o `physical_location` também não ajuda, porque a BIOS
reporta `top/upper/left` genérico para as 12 portas do barramento.

## Teste rápido (10 s, sem precisar suspender)

Ciclar a porta força a re-enumeração na hora — é isso que torna a caça física viável, em vez de
gastar um ciclo de suspend/resume por tentativa:

```bash
P=/sys/bus/usb/devices/usb3/3-0:1.0/usb3-port11
echo 1 | sudo tee $P/disable >/dev/null; sleep 2
echo 0 | sudo tee $P/disable >/dev/null; sleep 8
sudo dmesg -T | tail -12
```

## Como identificar o culpado

Desconectar os periféricos **externos** não resolve (já testado no Windows) — o suspeito está
dentro do gabinete. Com a máquina aberta, desconecte **um header USB interno por vez** (painel
frontal, AIO, controladora RGB, leitor de cartão), religue e rode o teste de 10 s acima:

- **Erro sumiu** → o culpado é o que estava naquele header.
- **Erro persiste com todos desconectados** → é a placa. Só resta desabilitar a porta.

Comece pelos headers que foram tocados na remoção do NV3, que é a correlação temporal.

## Mitigação atual

`usb-port-guard` (system service) desabilita a porta no boot e a cada resume. Instalado por
`make install-system`; fonte em `bin/usb-port-guard` e `systemd/usb-port-guard.service`.

**Eficácia medida (26/ago/2026), sem arredondar para cima:**

| Cenário | Antes | Depois |
|---|---|---|
| Resume | 8 ocorrências | **0** |
| Boot | 4-22 ocorrências | **6**, e então para |

No **resume** a eliminação é total: o guard dispara ~1 s após o `PM: suspend exit` e o barramento
volta com a porta já desabilitada.

No **boot** ele apenas interrompe: o kernel enumera o barramento por volta de 13:30:06 e o guard só
roda 10 s depois (13:30:16). Nenhum serviço de userspace chega antes da enumeração inicial do
kernel, então essas primeiras linhas são inevitáveis por esse caminho — o ganho é que a repetição
para em vez de continuar pelo boot afora. Como o uso normal do Ancalagon é acordar por WoL (resume,
não boot frio), na prática o log fica limpo quase sempre.

Para zerar também no boot **e** no Windows, a única saída é a BIOS (ver abaixo) — ou resolver o
problema físico.

**Não é uma regra udev por impossibilidade técnica:** portas USB expõem `SUBSYSTEM==""` e
`DRIVER==""` (conferido com `udevadm info -a`), então nenhuma regra casaria com elas.

Vale só no Linux. Para calar também no Windows, o caminho é a BIOS: **Advanced → USB Configuration
→ USB Single Port Control**, desabilitando a entrada correspondente (exige tentativa e erro para
descobrir qual, com o teste de 10 s confirmando).

Para reverter: `sudo systemctl disable --now usb-port-guard.service` e reabilitar a porta com
`echo 0 | sudo tee $P/disable`.
