import ArgumentParser
import VMCore

/// Shared shell completion for VM name arguments.
///
/// Use with `@Argument(completion: VMNameCompletion.kind)` so that Start, Stop,
/// Info, IP, SSH, Edit, Delete, Attach, Rescue, Resize, etc. all offer
/// tab-completion of existing VM names (excluding the rescue VM), filtered
/// by the current word prefix.
enum VMNameCompletion {
    static var kind: CompletionKind {
        .custom { _, _, prefix in
            let vms = (try? Manager.shared.listVMs()) ?? []
            let names = vms.filter { $0 != Manager.rescueVMName }
            return names.filter { $0.hasPrefix(prefix) }
        }
    }
}
