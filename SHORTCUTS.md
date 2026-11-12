# Starlight — atalhos para jogos específicos

**Starlight** é um fork do [Moonlight para iOS](https://github.com/moonlight-stream/moonlight-ios) (GPLv3), igual ao original, com uma única funcionalidade acrescentada:
**abrir diretamente o stream de um jogo a partir de um link**, para usar na app Atalhos,
no ecrã principal, em widgets ou com a Siri.

## Formato do link

```
starlight://launch?host=<PC>&app=<jogo>
```

| Parâmetro | Aceita | Exemplo |
|---|---|---|
| `host` (ou `pc`) | UUID do PC **ou** o nome do PC tal como aparece no Moonlight | `host=jmmorgado-pc` |
| `app` (ou `game`) | ID da app no Vibepollo **ou** o nome exato | `app=Steam%20Big%20Picture` |
| `name` | Opcional, só informativo (ignorado) | |

Espaços e acentos têm de ir codificados (`%20` para espaço). O mais fácil é não escrever
o link à mão: ver abaixo.

## Como criar um atalho

1. Abre a app, entra no PC e **mantém o dedo em cima do jogo**.
2. Escolhe **Copy Shortcut Link** — o link fica copiado.
3. Na app **Atalhos**: novo atalho → ação **Abrir URLs** → cola o link.
4. Dá-lhe nome e ícone e, se quiseres, **Adicionar ao ecrã principal**.

Ao tocar no atalho, a app abre, espera até ~6 segundos que o PC apareça na rede
e arranca logo o stream desse jogo. Se já estiver outro jogo a correr no PC, aparece
o menu normal do Moonlight (retomar / fechar e iniciar).

Se algo falhar (PC não emparelhado, jogo não encontrado), aparece um aviso a explicar.

## Compilar sem Mac (GitHub Actions)

O workflow `.github/workflows/build-ipa.yml` compila automaticamente a cada push
(ou manualmente em **Actions → Build unsigned IPA → Run workflow**) e gera o artefacto
`Starlight-ipa` com o ficheiro `Starlight.ipa` (não assinado).

## Instalar no iPhone a partir do Windows

**Sideloadly** (Apple ID grátis):
1. Descarrega o artefacto em Actions e extrai o `Starlight.ipa`.
2. Liga o iPhone por cabo ao PC, abre o Sideloadly, arrasta o `.ipa`, mete o teu Apple ID.
3. Em *Advanced options* podes mudar o **Bundle ID** (para conviver com o Moonlight oficial)
   e o **nome da app**.
4. No iPhone: Definições → Geral → VPN e gestão de dispositivos → confiar no teu Apple ID,
   e ativar o **Modo de programador** se for pedido.

Com Apple ID grátis a app expira ao fim de 7 dias: basta reinstalar o mesmo `.ipa`
(os dados ficam) ou usar o refresh automático do Sideloadly/AltStore.

Com conta de programador (99 USD/ano) a assinatura dura 1 ano.
