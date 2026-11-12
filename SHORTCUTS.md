# Starlight

## Ecrã principal

- **Início:** PC no topo (toca para mudar de PC ou ver outros PCs na rede), jogo em destaque com a arte de fundo,
  **Play** (ou **Resume** + **Quit** se o jogo estiver a correr), menu **•••** e as filas "Continue Playing" e "All Games".
  Os jogos fixados aparecem sempre primeiro.
- **Library:** todos os jogos do PC (capas verticais).
- **Barra de cima (nativa):** botão do PC à esquerda (menu do sistema) e, à direita, relógio, comando (PlayStation/Xbox), rede e bateria.
- **Barra de abas (nativa):** Home, Library e Settings; a **pesquisa** é o botão redondo em baixo à direita, que expande no campo de pesquisa. Com comando, L1/R1 mudam de aba.

## Navegar com comando
- **Cruz / stick esquerdo:** mexer entre os jogos · **✕:** abrir a página do jogo · **R2:** jogar · **Options:** opções do jogo (•••) · **○:** voltar
- **△:** pesquisa · **□:** PC · **L1/R1:** mudar de aba
- No stream: **Options + Share** (toque) = Guide no PC; mantidos 1 s = painel do stream.
- **Settings:** ecrãs nativos para **Stream Settings**, cada **PC** (emparelhar, acordar, atualizar jogos,
  testar rede, remover), **Hidden Games**, **Game Artwork** (SteamGridDB) e **About**.
- **Continue Playing:** só jogos iniciados nos últimos 30 dias (pela Starlight ou no PC, segundo a Steam) e o que estiver a correr. Se não houver nenhum, a fila não aparece.
- **Acordar o PC:** com **Settings → Launching → Wake PC Automatically** ligado (por omissão), um jogo fixado, um link starlight:// ou um Atalho acordam o PC por Wake-on-LAN e esperam até ~60 s antes de começar o stream. No menu do PC (botão em cima à direita ou □) aparece **Wake <PC>** quando está desligado.
- **Jogos escondidos:** "Hide Game" tira o jogo da Home, da Library e da pesquisa. Ficam em **Settings → Hidden Games**, onde **Show** (ou ✕) os traz de volta.
- **Settings com comando:** cruz para cima/baixo entre as opções · **✕** abre o ecrã, liga/desliga ou passa à opção seguinte · **← / →** mudam o valor (resolução, FPS, bitrate ±1 Mbps, codec, interruptores) · **○** volta atrás (ou fecha o teclado). Em campos de texto, ✕ abre o teclado. Ações de remover pedem **✕ duas vezes**.

# Atalhos para jogos específicos

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

## Fixar um jogo no ícone da app (o mais rápido)

1. Na app, toca em **•••** (ou mantém o dedo em cima do jogo) → **Pin**.
2. No ecrã principal do iPhone, mantém o dedo no ícone da **Starlight**: o jogo aparece no menu.
3. Tocar nele abre logo o ecrã de arranque com a arte do jogo e entra no stream,
   sem passar pelo ecrã principal da app.

Até 4 jogos (limite do iOS). Para tirar: **Unpin** no mesmo menu. Os jogos fixados também ficam nos primeiros lugares das listas da app.

## Atalho na app Atalhos (com o ícone do jogo)

1. Abre a app **Atalhos** → **+** → **Adicionar ação** → procura **Starlight** → **Start Game**.
2. Toca em *Game* e escolhe o jogo na lista (vem do Vibepollo, com a arte).
3. **Ícone do jogo:** na Starlight, **•••** (ou mantém o dedo no jogo) → **Save Icon to Photos**.
   No atalho: partilhar/ⓘ → **Adicionar ao ecrã principal** → toca no ícone → **Escolher foto**.

Também funciona com a Siri ("Start Cyberpunk 2077 in Starlight") e aparece no Spotlight.
A lista de jogos atualiza sempre que abres a app e ela lê a lista do PC.

## Como criar um atalho por link (alternativa)

1. Abre a app e toca em **•••** no jogo (ou mantém o dedo em cima dele).
2. Escolhe **Copy Shortcut Link** — o link fica copiado.
3. Na app **Atalhos**: novo atalho → ação **Abrir URLs** → cola o link.
4. Dá-lhe nome e ícone e, se quiseres, **Adicionar ao ecrã principal**.

Ao tocar no atalho, a app abre diretamente num ecrã de arranque com a arte do jogo,
espera até ~3 segundos que o PC apareça na rede e entra no stream. Se já estiver outro jogo a correr no PC, aparece
o menu normal do Moonlight (retomar / fechar e iniciar).

Se algo falhar (PC não emparelhado, jogo não encontrado), aparece um aviso a explicar.

## Arte dos jogos (SteamGridDB)

1. Em steamgriddb.com, entra com a conta Steam → **Preferences → API** → gera uma chave.
2. Na Starlight, vai a **Settings → Game Artwork** e cola a chave.
3. A app descarrega capa, fundo, logótipo e ícone de cada jogo. Os jogos novos são
   descarregados automaticamente. A chave fica só no iPhone.

## Compilar sem Mac (GitHub Actions)

O workflow `.github/workflows/build-ipa.yml` compila automaticamente a cada push
(ou manualmente em **Actions → Build unsigned IPA → Run workflow**) e publica uma
**release** com o `Starlight.ipa` (não assinado):
https://github.com/jmmorgado/starlight-ios/releases/latest

## Instalar no iPhone a partir do Windows

**Sideloadly** (Apple ID grátis):
1. Descarrega o `Starlight.ipa` da [última release](https://github.com/jmmorgado/starlight-ios/releases/latest).
2. Liga o iPhone por cabo ao PC, abre o Sideloadly, arrasta o `.ipa`, mete o teu Apple ID.
3. Em *Advanced options* podes mudar o **Bundle ID** (para conviver com o Moonlight oficial)
   e o **nome da app**.
4. No iPhone: Definições → Geral → VPN e gestão de dispositivos → confiar no teu Apple ID,
   e ativar o **Modo de programador** se for pedido.

Com Apple ID grátis a app expira ao fim de 7 dias: basta reinstalar o mesmo `.ipa`
(os dados ficam) ou usar o refresh automático do Sideloadly/AltStore.

Com conta de programador (99 USD/ano) a assinatura dura 1 ano.

## Corrigir a arte de um jogo

Se a SteamGridDB escolher a versão errada de um jogo (ex.: Ocarina of Time da N64 em vez de outra edição):

1. **•••** no jogo (ou mantém o dedo em cima dele) → **Edit Artwork…**
2. Em **Game**, pesquisa e escolhe o jogo certo.
3. Opcional: escolhe o **Background**, a **Cover** e o **Logo** que preferires entre as opções disponíveis.

A escolha fica guardada e é respeitada mesmo quando se volta a descarregar a arte.

## Steam

Em **Settings → Steam**, cola a tua Steam Web API key (gera-se em steamcommunity.com/dev/apikey) e o SteamID64 ou o URL/nome do perfil. A chave fica só no Keychain do iPhone. Os "Detalhes de jogo" do perfil Steam têm de estar públicos para aparecerem horas e achievements.

Se a app disser que o PC "isn't sharing its games", ativa **List applications** para este iPhone no Vibepollo (Web UI → Client Management).
