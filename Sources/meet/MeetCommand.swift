import ArgumentParser

@main
struct Meet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meet",
        abstract: "Record meetings (mic + system audio) and transcribe them locally."
    )
}
