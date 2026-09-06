use List::Util 'min';
sub EVENT_SAY {
    if (plugin::CustomEventSayEntry()) {
        return;
    }
    
    if (plugin::MultiClassingEnabled() && $npc->GetClass() >= 20 && $npc->GetClass() <= 35) {
        my $classes = $client->GetClassesBitmask();
        my $player_class_id = $npc->GetClass() - 19;
        my $class_name = quest::getclassname($player_class_id);

        if ($text=~/hail/i) {
            my $select_string = quest::saylink("class_select", 1, "become a $class_name");
            my %class_greetings = (
                1 => "Ah, a courageous soul approaches. Are you here to embrace the discipline and strength required to [$select_string]?",
                2 => "Blessings upon you, child. The light guides you to me; is it your wish to [$select_string] and serve the divine?",
                3 => "Honor and valor shine from your eyes. Are you destined to [$select_string], a righteous defender of the light?",
                4 => "The winds whisper of a new guardian. Is your heart called to the wilds, to [$select_string], protector of nature?",
                5 => "A shadow looms near. Is it your fate to command the darkness and [$select_string]?",
                6 => "The essence of nature surrounds you. Are you ready to [$select_string], guardian of the balance?",
                7 => "Discipline and inner strength are your allies. Do you seek the path to [$select_string], master of martial arts?",
                8 => "A melody accompanies your steps. Do you feel the rhythm calling you to [$select_string], the voice of inspiration?",
                9 => "Cunning and silence are your markers. Are you prepared to [$select_string], master of stealth and treachery?",
                10 => "The spirits whisper of a new journey. Is it time for you to [$select_string], a conduit of the spirit world?",
                11 => "A chill of the grave precedes you. Will you embrace the dark arts and [$select_string]?",
                12 => "Arcane energies pulse around you. Is your destiny to [$select_string], master of the elements?",
                13 => "Creation's essence swirls around you. Are you called to [$select_string], summoner of the arcane?",
                14 => "Your presence bends reality. Are you ready to [$select_string], weaver of illusions and mind control?",
                15 => "The call of the wild strengthens. Will you heed the call and [$select_string], melding the power of beasts and combat?",
                16 => "Rage burns within your spirit. Do you wish to unleash this power and [$select_string], a warrior of frenzy?"
            );
            
            my $greeting = $class_greetings{$player_class_id} // "Greetings, traveler. Are you seeking guidance or knowledge?";
            my $has_class = ($classes & plugin::GetClassBitmask($player_class_id)) ? 1 : 0;
            my $reason = plugin::CanAddClass($client, $player_class_id);
            my %class_map = plugin::GetClassMap();
            my (@class_levels, $catchup_class_name, $catchup_class_level);
            foreach my $class_id (sort { $a <=> $b } keys %class_map) {
                if ($classes & plugin::GetClassBitmask($class_id)) {
                    my $class_level = plugin::GetClassLevel($client, $class_id);
                    push @class_levels, "$class_map{$class_id} $class_level";
                    if (!defined($catchup_class_level) || $class_level < $catchup_class_level) {
                        $catchup_class_name = $class_map{$class_id};
                        $catchup_class_level = $class_level;
                    }
                }
            }
            my $class_summary = "Your classes: " . join(", ", @class_levels) . ".";
            if (plugin::IsCatchingUp($client)) {
                $class_summary .= " You fight as level $catchup_class_level until $catchup_class_name reaches " . plugin::GetRewardLevel($client) . ".";
            }

            if (!$has_class && $reason == 0) {
                plugin::NPCTell("$greeting A new class begins at level 1 and your effective level becomes the lowest of your classes until it catches up.");
            } elsif ($has_class) {
                plugin::NPCTell("You already walk the path of the $class_name; there is nothing more I can teach you.");
            } else {
                plugin::NPCTell(plugin::CanAddClassMessage($client, $player_class_id));
            }
            plugin::NPCTell($class_summary);
        }        

        if ($text eq "class_select") {
            if (plugin::GetClassesCount($client) < plugin::MaxMulticlasses() && plugin::CanAddClass($client, $player_class_id) == 0) {
                if (plugin::AddClass($player_class_id)) {
                    plugin::NPCTell("Welcome, $class_name, and be known!");
                }
            } else {
                plugin::NPCTell(plugin::CanAddClassMessage($client, $player_class_id));
            }
            return;
        }

        if ($text eq "class_confirm") {
            return;
        }

    }
}

sub EVENT_DEATH_COMPLETE {
    plugin::CustomEventNPCDeathEntry($killer_id);
    plugin::SpawnProgressionFlagNPC($npc); # stage-flag bosses table in NMS_expansion_unlock.pl

    if (defined($killed_corpse_id)) {
        my $corpse = $entity_list->GetCorpseByID($killed_corpse_id);
        if ($corpse) {        
            my %item_drops = (
                11703 => { #Box of Abu Kar 11703
                    'drop_chance' => 0.0001, # 1/1000% chance to drop
                    'min_level'   => 35, # Minimum level to drop from
                    'max_level'   => 99, # Maximum level to drop from
                },
                #2827 => { # Christmas Event
                #    'drop_chance' => 0.01,
                #    'min_level'   => 1, # Minimum level to drop from
                #    'max_level'   => 99, # Maximum level to drop from
                #},
                #56064 => { 
                #    'drop_chance' => 0.0005, # 5/1000% chance to drop
                #    'min_level'   => 1, # Minimum level to drop from
                #    'max_level'   => 99, # Maximum level to drop from
                #},
                #36013 => { 
                #    'drop_chance' => 0.0005, # 5/1000% chance to drop
                #    'min_level'   => 1, # Minimum level to drop from
                #    'max_level'   => 99, # Maximum level to drop from
                #}
                # ... more items and their attributes
            );

            for my $item_id (keys %item_drops) {
                if ($npc->GetLevel() >= $item_drops{$item_id}{'min_level'} && 
                    $npc->GetLevel() <= $item_drops{$item_id}{'max_level'}) {                    
                    if (rand() < $item_drops{$item_id}{'drop_chance'}) {
                        $corpse->AddItem($item_id, 1);
                        $corpse->SetDecayTimer(1500000);
                        quest::ding();
                    }
                }
            }
        }
    }
}

sub EVENT_AGGRO {
    if (plugin::IsNMS() && $instanceid) {
        my $expedition = quest::get_expedition();
        if ($expedition) {
            plugin::ScaleInstanceNPC($npc, $expedition->GetMemberCount());
        }
    }
}

sub EVENT_SIGNAL {
    if ($signal == 66666) {
        my $expedition = quest::get_expedition();
        if ($expedition) {
            plugin::ScaleInstanceNPC($npc, $expedition->GetMemberCount());
        }
    }
}

sub EVENT_ITEM {
    if (plugin::CustomEventHandinEntry()) {
        return 1;
    }
}

sub EVENT_SPAWN {
    if (plugin::CustomEventNPCSpawnEntry($npc)) {
        return;
    }

    
    if ($instanceversion > 0) {        
        if ($npc->GetName() =~ /Echo_of_the_Past/) {
            $npc->Depop(0);
        }
    }

    if (plugin::IsNMS() && $instanceid) {
        my $expedition = quest::get_expedition();
        if ($expedition) {
            plugin::ScaleInstanceNPC($npc, $expedition->GetMemberCount());
        }
    }
}

sub EVENT_DAMAGE_GIVEN 
{
    # Special aggro events for player pets; if they are not taunting then add their owner to any
    # mob that they attack's aggro list. If they are taunting, then give them some bonus aggro.
    if ($npc->IsPet() && $npc->GetOwner()->IsClient()) {
       
        if ($npc->IsTaunting()) {
            my $ent = $entity_list->GetMobByID($entity_id);
            if ($ent) {
                $ent->AddToHateList($npc->GetOwner())
            }
        } else {
            my $ent = $entity_list->GetMobByID($entity_id);
            if ($ent) {
                $ent->AddToHateList($npc, 100);
            }
        }
    }
}

sub EVENT_KILLED_MERIT {
    plugin::ProcessSlayerCredit($client, $npc, $entity_list);
}
