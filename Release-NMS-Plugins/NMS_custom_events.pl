# NMS_custom_events.pl
#
# Extension points for a server built on this release. The global scripts
# (global/global_npc.pl, global/global_player.pl) and NMS_multiclass_utils.pl
# call these BEFORE their own logic. Each hook runs inside the event that
# triggered it, so the normal event globals ($npc, $client, $text, $item1..,
# %itemcount, $slot_id, $item_id, ...) are in scope via plugin::val().
#
# Contract for the hooks marked "gating": the caller does
#     if (plugin::CustomEventXEntry(...)) { return; }
#   return 0  -> "not handled", the caller continues with its default behaviour
#   return 1  -> "handled", the caller returns immediately and does nothing else
# Hooks marked "notify" are called for their side effects only; the return
# value is ignored.
#
# Keep them cheap: EVENT_SAY and EVENT_EXP_GAIN fire constantly.

# gating - EVENT_SAY on every NPC (global_npc.pl). Return 1 to swallow the say,
# including the multiclass trainer dialogue.
sub CustomEventSayEntry {
    return 0;
}

# notify - EVENT_DEATH_COMPLETE on every NPC (global_npc.pl). Args: $killer_id.
sub CustomEventNPCDeathEntry {
    my $killer_id = shift;
    return 0;
}

# gating - EVENT_ITEM on every NPC (global_npc.pl), before the stock hand-in
# path. If you return 1 you must consume or return the items yourself.
sub CustomEventHandinEntry {
    return 0;
}

# gating - EVENT_SPAWN on every NPC (global_npc.pl). Args: $npc.
sub CustomEventNPCSpawnEntry {
    my $npc = shift;
    return 0;
}

# notify - EVENT_EXP_GAIN / EVENT_AA_EXP_GAIN (global_player.pl).
sub CustomEventExpGainEntry {
    return 0;
}

sub CustomEventAAExpGainEntry {
    return 0;
}

# notify - EVENT_EQUIP_ITEM_CLIENT / EVENT_UNEQUIP_ITEM_CLIENT (global_player.pl).
sub CustomEventItemEquipEntry {
    return 0;
}

sub CustomEventItemUnequipEntry {
    return 0;
}

# notify - EVENT_DESTROY_ITEM_CLIENT (global_player.pl). Args: $item, $quantity.
sub CustomEventDestroyEntry {
    my ($item, $quantity) = @_;
    return 0;
}

# gating - EVENT_ITEM_CLICK_CAST_CLIENT (global_player.pl). Return 1 to block
# the click cast.
sub CustomEventItemClickCastEntry {
    return 0;
}

# Echo of Memory awards.
#
# #award [Character] [Amount] [Reason] (zone/gm_commands/award.cpp) does not
# credit currency directly; it adds Amount to the character's "EoM-Award" data
# bucket and fires cross-zone signal 666. This hook consumes that bucket. It is
# called from global_player.pl on signal 666 and from
# plugin::CommonCharacterUpdate on every zone-in, so an award to an offline
# character lands the next time they log in.
#
# EoM is alternate currency id 6 (EOM_CURRENCY_ID, world/client.h). With
# Custom:EnableAccountAltCurrency on, AddAlternateCurrencyValue credits the
# account-wide balance in account_alt_currency.
sub UpdateEoMAward {
    my $client = shift || plugin::val('$client');
    return 0 unless ($client && $client->IsClient());

    my $pending = $client->GetBucket('EoM-Award');
    return 0 unless (defined $pending && $pending =~ /^\d+$/ && $pending > 0);

    $client->AddAlternateCurrencyValue(6, $pending);
    $client->DeleteBucket('EoM-Award');
    $client->Message(15, "You have been awarded $pending Echo of Memory.");
    return 1;
}

# Called from plugin::CommonCharacterUpdate on every zone-in. Hand out
# seasonal / event rewards here.
sub DoEventRewards {
    return 0;
}

1;
