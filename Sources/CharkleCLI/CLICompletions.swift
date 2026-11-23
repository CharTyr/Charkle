import Foundation

enum CLICompletions {
    static func script(for shell: String) -> String? {
        switch shell.lowercased() {
        case "zsh": return zshScript
        case "bash": return bashScript
        case "fish": return fishScript
        default: return nil
        }
    }

    private static let zshScript = #"""
    #compdef charkle

    _charkle() {
      local -a commands
      commands=(
        'mcp:Run native stdio MCP JSON-RPC 2.0 server'
        'doctor:Run library, policy, symlink, and MCP diagnostics'
        'status:Show library overview & external agent access status'
        'overview:Show folders, smart folders, tags, and media counts'
        'search:Search & paginate assets with full filters'
        'semantic:Run hybrid semantic search'
        'similar:Find visually similar assets'
        'jump:Unified fuzzy quick jump across folders, boards, tags, assets'
        'inbox:List untriaged Inbox assets (optional --suggest)'
        'asset:Inspect full asset metadata including EXIF & AI prompts'
        'contact-sheet:Render numbered visual contact sheet JPEG'
        'board:List, inspect, export, compose, or patch moodboards'
        'folder:List, create, rename, move, or style folders'
        'organize:Batch-organize assets (folder, tags, rating, notes, AI desc)'
        'analyze:Run local Vision OCR/colors/EXIF analysis'
        'import:Import local files/folders, URLs, or text snippets'
        'trash:List Trash or soft-move/restore assets'
        'completions:Generate zsh, bash, or fish shell completions'
      )

      _arguments -C \
        '--library-dir[Override Charkle Application Support directory]:dir:_files -/' \
        '--json[Force pretty JSON output]' \
        '--compact[Force single-line compact JSON output]' \
        '--no-color[Disable ANSI colors]' \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-v --version)'{-v,--version}'[Print version]' \
        '1:command:->cmd' \
        '*::arg:->args'

      case "$state" in
        cmd)
          _describe 'command' commands
          ;;
        args)
          case "$words[1]" in
            board)
              local -a subcmds
              subcmds=('list:List all moodboards' 'get:Inspect moodboard context' 'export:Export moodboard PNG' 'compose:Create a moodboard' 'patch:Modify an existing moodboard')
              _describe 'board subcommand' subcmds
              ;;
            folder)
              local -a subcmds
              subcmds=('list:List folder hierarchy' 'create:Create a folder' 'rename:Rename a folder' 'move:Move a folder' 'update:Update folder name, parent, or appearance')
              _describe 'folder subcommand' subcmds
              ;;
            completions)
              _values 'shell' zsh bash fish
              ;;
          esac
          ;;
      esac
    }

    compdef _charkle charkle
    """#

    private static let bashScript = #"""
    _charkle_completions() {
      local cur prev words cword
      cur="${COMP_WORDS[COMP_CWORD]}"
      prev="${COMP_WORDS[COMP_CWORD-1]}"

      local commands="mcp doctor status overview search semantic similar jump inbox asset contact-sheet board folder organize analyze import trash completions"
      if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands --help --version --library-dir --json --compact" -- "$cur") )
        return 0
      fi

      case "${COMP_WORDS[1]}" in
        board)
          if [[ $COMP_CWORD -eq 2 ]]; then
            COMPREPLY=( $(compgen -W "list get export compose patch --help" -- "$cur") )
          fi
          ;;
        folder)
          if [[ $COMP_CWORD -eq 2 ]]; then
            COMPREPLY=( $(compgen -W "list create rename move update --help" -- "$cur") )
          fi
          ;;
        completions)
          if [[ $COMP_CWORD -eq 2 ]]; then
            COMPREPLY=( $(compgen -W "zsh bash fish" -- "$cur") )
          fi
          ;;
        search)
          COMPREPLY=( $(compgen -W "--folder --subfolders --tag --kind --shape --color --min-rating --sort --smart-folder --inbox --untagged --trashed --recent-days --offset --limit --json --compact --help" -- "$cur") )
          ;;
      esac
    }
    complete -F _charkle_completions charkle
    """#

    private static let fishScript = #"""
    complete -c charkle -f
    complete -c charkle -n "__fish_use_subcommand" -a "mcp" -d "Run native stdio MCP JSON-RPC 2.0 server"
    complete -c charkle -n "__fish_use_subcommand" -a "doctor" -d "Run diagnostics"
    complete -c charkle -n "__fish_use_subcommand" -a "status" -d "Show library & access status"
    complete -c charkle -n "__fish_use_subcommand" -a "overview" -d "Show library overview"
    complete -c charkle -n "__fish_use_subcommand" -a "search" -d "Search assets with filters & pagination"
    complete -c charkle -n "__fish_use_subcommand" -a "semantic" -d "Hybrid semantic search"
    complete -c charkle -n "__fish_use_subcommand" -a "similar" -d "Find visually similar assets"
    complete -c charkle -n "__fish_use_subcommand" -a "jump" -d "Unified fuzzy quick jump"
    complete -c charkle -n "__fish_use_subcommand" -a "inbox" -d "List Inbox assets"
    complete -c charkle -n "__fish_use_subcommand" -a "asset" -d "Inspect full asset metadata"
    complete -c charkle -n "__fish_use_subcommand" -a "contact-sheet" -d "Render visual contact sheet JPEG"
    complete -c charkle -n "__fish_use_subcommand" -a "board" -d "Manage moodboards (list|get|export|compose|patch)"
    complete -c charkle -n "__fish_use_subcommand" -a "folder" -d "Manage folders (list|create|rename|move|update)"
    complete -c charkle -n "__fish_use_subcommand" -a "organize" -d "Batch-organize assets"
    complete -c charkle -n "__fish_use_subcommand" -a "analyze" -d "Run local Vision analysis"
    complete -c charkle -n "__fish_use_subcommand" -a "import" -d "Import files, URLs, or text"
    complete -c charkle -n "__fish_use_subcommand" -a "trash" -d "List or soft-trash/restore assets"
    complete -c charkle -n "__fish_use_subcommand" -a "completions" -d "Generate shell completions (zsh|bash|fish)"
    complete -c charkle -n "__fish_seen_subcommand_from board" -a "list get export compose patch"
    complete -c charkle -n "__fish_seen_subcommand_from folder" -a "list create rename move update"
    complete -c charkle -n "__fish_seen_subcommand_from completions" -a "zsh bash fish"
    """#
}
