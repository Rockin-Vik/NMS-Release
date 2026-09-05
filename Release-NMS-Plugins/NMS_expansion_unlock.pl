# NMS expansion unlock - the one place to edit when opening an expansion.
#
# Three data tables and two subs. Everything else in the progression system reads from here at
# call time (never at load time: plugins are eval'd into package plugin in directory order, so
# another file's data is not guaranteed to exist while this one is loading).
#
#   %UNLOCKED_STAGES   which stages the time lock lets through on NMS servers
#   %FLAG_BOSSES       which boss deaths spawn the memory NPC (26000) that grants a stage flag
#   %STAGE_ENTRY       where the Magus in the Bazaar sends a player who holds the flag
#
# Wiring (each is a one-line call):
#   NMS_progression_utils.pl  is_time_locked      -> %plugin::UNLOCKED_STAGES
#   global/global_npc.pl      EVENT_DEATH_COMPLETE -> plugin::SpawnProgressionFlagNPC($npc)
#   bazaar/Magus_Alaria.pl    EVENT_SAY            -> plugin::MagusExpansionPort($client, $text)
#   global/global_player.pl   EVENT_ENTERZONE      -> plugin::GMUnlockAll($client)
#
# The stage prerequisite list itself (%STAGE_PREREQUISITES) stays in NMS_progression_utils.pl
# because that file builds lookups from it at load time. Opening an expansion is therefore:
#   1. add the stage to %UNLOCKED_STAGES here
#   2. add its gate boss to %FLAG_BOSSES here
#   3. add an entry route to %STAGE_ENTRY here (skip if the zone is reachable on foot)
#   4. replace 'Disabled' with the boss name in %STAGE_PREREQUISITES in NMS_progression_utils.pl

# Stages the time lock allows on NMS (multiclass) servers. Order does not matter.
our %UNLOCKED_STAGES = map { $_ => 1 } qw(RoK SoV SoL PoP GoD OoW DoN);

# Boss death => stage flag. Keyed by npc_type id when the boss is renamed mid-fight with TempName()
# (CleanMobName() strips the spaces from a temp name, so a name lookup would never match) and by
# lowercased clean name otherwise, so the row works without the DB id in hand. Name-keyed rows MUST
# carry 'zone' (short name): boss names repeat across zones (Plane of Time has its own Saryrn) and
# only the real encounter may mint the flag. A boss must NOT appear here if its own script already
# spawns the memory NPC or calls plugin::handle_death, or it spawns twice. The 'flag' value must
# equal the entry in %STAGE_PREREQUISITES, lowercased.
our %FLAG_BOSSES = (
    'saryrn'              => { stage => 'GoD', flag => 'saryrn',                zone => 'potorment' },
    298055                => { stage => 'OoW', flag => 'tunat`muram cuu vauax', zone => 'tacvi'     }, # final form of Tunat`Muram
    'overlord mata muram' => { stage => 'DoN', flag => 'overlord mata muram',   zone => 'anguish'   },
);

# Stage => Magus destination. 'say' is what the player says (offered in brackets on hail).
# Coordinates are the zone-in used by the old per-zone code (GoD) or the nms_waypoints row (OoW),
# so the rune circle there can be unlocked on arrival. DoN has no row: the Broodlands is entered on
# foot from Lavastorm, which is open, and the stage gate is enforced at EVENT_ENTERZONE.
our %STAGE_ENTRY = (
    GoD => { say => "Nedaria's Landing", match => qr/nedaria/i,           zone_sn => 'nedaria',         zone => 182, x => 1463, y => 1053, z => 82.86, h => 136 },
    OoW => { say => "Wall of Slaughter", match => qr/wall of slaughter/i, zone_sn => 'wallofslaughter', zone => 300, x => -943, y => 13,   z => 130,   h => 0   },
);

# Called from global_npc.pl on every NPC death. Cheap hash miss for anything not in the table.
# Mirrors plugin::handle_death: on NMS the memory NPC only appears inside a progression instance,
# and the hail in global/26000.pl enforces the same rule again.
sub SpawnProgressionFlagNPC {
    my ($npc) = @_;
    return 0 unless $npc;

    my $name = lc($npc->GetCleanName() // '');
    $name =~ s/^[#\s]+|[#\s]+$//g;
    my $boss = $FLAG_BOSSES{ $npc->GetNPCTypeID() } || $FLAG_BOSSES{$name};
    return 0 unless $boss;

    # Same-named NPCs exist in other zones; only the listed zone's encounter counts.
    if ($boss->{zone}) {
        my $zonesn = plugin::val('$zonesn') // '';
        return 0 unless lc($zonesn) eq lc($boss->{zone});
    }

    if (plugin::MultiClassingEnabled()) {
        my $zoneid          = plugin::val('$zoneid');
        my $instanceid      = plugin::val('$instanceid');
        my $instanceversion = plugin::val('$instanceversion');
        return 0 unless plugin::ValidProgInstance($zoneid, $instanceid, $instanceversion);
    }

    my $entity_list = plugin::val('$entity_list');
    my $spawned_id  = quest::spawn2(26000, 0, 0, $npc->GetX(), $npc->GetY(), $npc->GetZ() + 10, $npc->GetHeading());
    my $memory      = $entity_list ? $entity_list->GetNPCByID($spawned_id) : undef;
    return 0 unless $memory;

    $memory->SetEntityVariable("Flag-Name",  $boss->{flag});
    $memory->SetEntityVariable("Stage-Name", $boss->{stage});
    return 1;
}

# Bracketed destination list for the Magus hail text, in stage order.
sub MagusExpansionOffers {
    return join(", ", map { "[" . $STAGE_ENTRY{$_}{say} . "]" } grep { $STAGE_ENTRY{$_} } qw(GoD OoW DoN));
}

# Called from the Magus EVENT_SAY. Returns 1 if the text named a destination (ported or denied),
# 0 if it was not about an expansion port. is_eligible_for_zone keeps the GM bypass and prints
# the deny message itself.
sub MagusExpansionPort {
    my ($client, $text) = @_;
    return 0 unless $client && defined $text;

    foreach my $stage (qw(GoD OoW DoN)) {
        my $entry = $STAGE_ENTRY{$stage} or next;
        next unless $text =~ $entry->{match};

        return 1 unless plugin::is_eligible_for_zone($client, $entry->{zone_sn}, 1);
        $client->MovePC($entry->{zone}, $entry->{x}, $entry->{y}, $entry->{z}, $entry->{h});
        return 1;
    }
    return 0;
}

# GM accounts at or above Custom:GMUnlockMinStatus get every progression flag on zone entry (the
# server runs EVENT_ENTERZONE before EVENT_CONNECT, and the zone-eligibility bounce lives there).
# Non-GM accounts return after one rule read and one status compare. Waypoints need nothing here:
# Client::GetUnlockedWaypoints returns the whole map for the same status.
sub GMUnlockAll {
    my ($client) = @_;
    return 0 unless $client;
    my $min_status = quest::get_rule("Custom:GMUnlockMinStatus") || 0;
    return 0 unless $min_status > 0 && $client->Admin() >= $min_status;
    my $granted = plugin::GrantAllProgression($client);
    $client->Message(263, "GM: $granted progression flag(s) granted.") if $granted;
    return 1;
}

1;
