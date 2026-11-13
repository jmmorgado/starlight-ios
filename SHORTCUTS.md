# Starlight: guia de utilização

Guia prático em português. A descrição geral, a instalação e a compilação estão no [README](README.md).

## Ecrã principal

- **Home:** jogo em destaque com a arte de fundo, **Play** (ou **Resume** + **Quit** se o jogo estiver a correr),
  menu **•••** e as filas **Continue Playing** e **Ready to Play**. Os jogos fixados aparecem sempre primeiro.
- **Library:** a coleção completa: todos os jogos Steam que tens, mais tudo o que está no PC, juntos pelo appid da Steam.
  Os jogos instalados no PC têm o selo **Ready to Play**. Filtros All / Ready to Play / Not Installed e ordenação por nome, jogado recentemente ou mais jogado.
- **Barra de cima (nativa):** à direita, o botão do PC (com o estado online/offline/não emparelhado), relógio, comando, rede e bateria.
- **Barra de abas (nativa):** Home, Library e Settings. A **pesquisa** é o botão redondo em baixo à direita.
- **Continue Playing:** jogos iniciados nos últimos 30 dias (pela Starlight ou no PC, segundo a Steam) e o que estiver a correr. Se não houver nenhum, a fila não aparece.
- **Jogos escondidos:** **Hide Game** tira o jogo da Home, da Library e da pesquisa. Ficam em **Settings → Hidden Games**, onde **Show** os traz de volta.

## Navegar com comando

- **Cruz / stick esquerdo:** mexer entre os jogos · **✕ / A:** abrir a página do jogo · **R2:** jogar · **Options:** opções do jogo · **○ / B:** voltar
- **△ / Y:** pesquisa · **□ / X:** PC · **L1 / R1:** mudar de aba
- **Settings:** cruz para cima/baixo entre opções · **✕** abre, liga/desliga ou avança · **← / →** mudam o valor (resolução, FPS, bitrate ±1 Mbps, codec, interruptores) · **○** volta atrás. Em campos de texto, ✕ abre o teclado. Ações de remover pedem **✕ duas vezes**.
- **No stream:** o iOS 26 reserva o botão Home para a app Jogos da Apple, por isso a Starlight usa **Start + Select** (Options + Share, Menu + View):
  um toque nos dois envia **Guide** para o PC; mantidos 1 segundo abrem o painel do stream. Deslizar da margem esquerda também abre o painel.

## Acordar o PC (Wake-on-LAN)

Com **Settings → Launching → Wake PC Automatically** ligado (por omissão), um jogo fixado, um link `starlight://` ou um Atalho
acordam o PC e esperam até ~60 segundos que ele apareça na rede antes de começar o stream.
Com o PC desligado, o menu do PC (botão em cima à direita ou □) mostra **Wake <PC>**.

## Fixar um jogo no ícone da app (o mais rápido)

1. Na app, **•••** no jogo (ou mantém o dedo em cima dele) → **Pin**.
2. No ecrã principal do iPhone, mantém o dedo no ícone da **Starlight**: o jogo aparece no menu.
3. Tocar nele abre logo o ecrã de arranque com a arte do jogo e entra no stream.

Até 4 jogos (limite do iOS). Para tirar: **Unpin** no mesmo menu.

## Ação "Start Game" na app Atalhos

1. App **Atalhos** → **+** → **Adicionar ação** → procura **Starlight** → **Start Game**.
2. Toca em *Game* e escolhe o jogo (a lista vem do PC, com a arte).
3. **Ícone do jogo:** na Starlight, **•••** → **Save Icon to Photos**. No atalho: ⓘ → **Adicionar ao ecrã principal** → toca no ícone → **Escolher foto**.

Também funciona com a Siri ("Start Cyberpunk 2077 in Starlight") e no Spotlight.
A lista de jogos atualiza sempre que abres a app e ela lê a lista do PC.

## Links `starlight://` (alternativa)

```
starlight://launch?host=<PC>&app=<jogo>
```

| Parâmetro | Aceita | Exemplo |
|---|---|---|
| `host` (ou `pc`) | UUID do PC **ou** o nome do PC | `host=jmmorgado-pc` |
| `app` (ou `game`) | ID da app no Vibepollo/Sunshine **ou** o nome exato | `app=Steam%20Big%20Picture` |

Espaços e acentos têm de ir codificados (`%20` para espaço). O mais fácil é não escrever o link à mão:

1. **•••** no jogo → **Copy Shortcut Link**.
2. App **Atalhos** → novo atalho → ação **Abrir URLs** → cola o link.
3. Dá-lhe nome e ícone e, se quiseres, **Adicionar ao ecrã principal**.

Se já estiver outro jogo a correr no PC, a app pergunta se queres retomá-lo ou fechá-lo e iniciar o novo.
Se algo falhar (PC não emparelhado, jogo não encontrado), aparece um aviso a explicar.

## Arte dos jogos

Para cada imagem (capa, fundo, logótipo), em todos os jogos (instalados ou não), a app usa a primeira fonte que a tiver:

1. A tua escolha no **Edit Artwork**
2. A arte oficial da Steam, nos jogos com appid
3. A SteamGridDB: pelo appid ou, nos jogos que não são da Steam (ex.: The Legend of Zelda emulado), pelo nome

O ícone salta a Steam (os ícones da Steam são demasiado pequenos). A arte da Steam não precisa de chave. Para a SteamGridDB:

1. Em steamgriddb.com, entra com a conta Steam → **Preferences → API** → gera uma chave.
2. Na Starlight, **Settings → Game Artwork** → cola a chave. Fica guardada no Keychain do dispositivo.

Os jogos da Library que não estão no PC descarregam a arte à medida que aparecem no ecrã.

### Corrigir a arte de um jogo

Funciona em todos os jogos, incluindo os que não estão no PC.

1. **•••** no jogo (ou mantém o dedo em cima dele) → **Edit Artwork…**
2. Em **Game**, pesquisa e escolhe o jogo certo.
3. Opcional: escolhe o **Background**, a **Cover** e o **Logo** que preferires.

A escolha fica guardada e é respeitada quando se volta a descarregar a arte. Escolher o jogo em **Game** faz esse jogo usar a SteamGridDB em vez da arte da Steam.

## Steam

Em **Settings → Steam**, cola a Steam Web API key (gera-se em steamcommunity.com/dev/apikey) e o SteamID64 ou o URL do perfil.
A chave fica no Keychain do dispositivo. Os "Detalhes de jogo" do perfil Steam têm de estar públicos para aparecerem horas e achievements.

## O PC "isn't sharing its games"

Ativa **List applications** para este dispositivo no Vibepollo (Web UI → Client Management).
