import SwiftUI

struct LiveTVHomeShelf: View {
    let viewModel: LiveTVViewModel
    let play: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void
    var directionalSelectionID: String?
    var usesDirectionalSelection = false

    var body: some View {
        if let lineup = viewModel.nowPlayingLineup {
            let currentPrograms = lineup.guides.compactMap { guide -> (PlexLiveChannel, PlexLiveProgram)? in
                guard let program = guide.currentProgram() else { return nil }
                return (guide.channel, program)
            }

            if !currentPrograms.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Live TV")
                        .font(.title2.bold())
                        .foregroundStyle(Color.duskTextPrimary)
                        .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)

                    ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(currentPrograms, id: \.1.id) { channel, program in
                                Button {
                                    play(channel, program, lineup)
                                } label: {
                                    LiveTVProgramCard(
                                        program: program,
                                        imageURL: viewModel.imageURL(
                                            for: program.preferredLandscapePath,
                                            width: 640,
                                            height: 360
                                        ),
                                        channelLogoURL: viewModel.imageURL(
                                            for: channel.thumb,
                                            width: 256,
                                            height: 256
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .focusable(!usesDirectionalSelection)
                                .duskDirectionalFocusHighlight(
                                    directionalSelectionID == program.id,
                                    shape: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .id(program.id)
                                .duskTVOSFocusEffectShape(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                            }
                        }
                        .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: directionalSelectionID) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    }
                }
            }
        }
    }
}
