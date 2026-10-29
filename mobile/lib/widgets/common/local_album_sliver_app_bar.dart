import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/widgets/common/tab_top_bar.dart';

class LocalAlbumsSliverAppBar extends StatelessWidget {
  const LocalAlbumsSliverAppBar({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverScrollUnder(
      sliver: SliverAppBar(
        floating: true,
        pinned: true,
        forceMaterialTransparency: true,
        flexibleSpace: const TabTopBarBackground(fillParent: true),
        snap: false,
        backgroundColor: context.colorScheme.surfaceContainer,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
        automaticallyImplyLeading: true,
        centerTitle: true,
        title: Text(context.t.on_this_device),
      ),
    );
  }
}
