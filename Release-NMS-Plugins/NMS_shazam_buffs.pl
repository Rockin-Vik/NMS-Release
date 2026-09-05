# Shazam buffbot
# Players say "Shazam!" in any chat channel, anywhere, and receive a full set of
# level-appropriate buffs cast instantly by the server. No NPC involved.
#
# Wiring: global/global_player.pl EVENT_SAY calls
#   return if plugin::ShazamBuffs($client, $text);
# Returns 1 when the message was a Shazam trigger (handled), 0 otherwise.
#
# Tuning knobs:
#   Cooldown      -> $SHAZAM_COOLDOWN (seconds)
#   Trigger word  -> $SHAZAM_TRIGGER regex
#   Tier bounds   -> @SHAZAM_TIERS (max level per tier, ascending)
#   Buffs         -> the spell-ID lists in %SHAZAM_BUFFS
#   Levitate      -> $SHAZAM_LEVITATE (spell id, 0 to disable)

our $SHAZAM_COOLDOWN = 60;
our $SHAZAM_LEVITATE = 261;   # Levitate - cast in every tier when the zone allows it
our $SHAZAM_TRIGGER  = qr/\bshazam\b/i;
our $SHAZAM_BUCKET   = "shazam_cooldown";

# Tier name => max level. Order matters (ascending). Last tier is the catch-all.
our @SHAZAM_TIERS = (
    [ "01_20" => 20 ],
    [ "21_45" => 45 ],
    [ "46_58" => 58 ],
    [ "59_up" => 999 ],
);

our %SHAZAM_BUFFS = (
    "01_20" => [
        18,     # Guard                     (Cleric   - AC)
        244,    # Bravery                   (Cleric   - HP, AC)
        486,    # Symbol of Ryltan          (Cleric   - HP)
        43,     # Yaulp II                  (Cleric   - STR, AC)
        3575,   # Blessing of Piety         (Cleric   - Spell Haste)
        326,    # Fury                      (Shaman   - AC, AGI, STR, DEX)
        161,    # Health                    (Shaman   - STA)
        151,    # Raging Strength           (Shaman   - STR)
        144,    # Regeneration              (Shaman   - HP Regen)
        649,    # Protect                   (Shaman   - AC)
        278,    # Spirit of Wolf            (Shaman   - Runspeed)
        174,    # Clarity                   (Enchanter- Mana Regen)
        170,    # Alacrity                  (Enchanter- Haste)
        21,     # Berserker Strength        (Enchanter- STR, AGI, Absorb DMG)
        479,    # Inferno Shield            (Magician - Damage Shield)
        2513,   # Protection of Steel       (Druid    - AC, HP)
        517,    # Bramblecoat               (Druid    - Damage Shield)
        129,    # Shield of Brambles        (Druid    - Damage Shield)
        254,    # Firefist                  (Ranger   - ATK)
        2592,   # Hawk Eye                  (Ranger   - Skills +60%)
    ],
    "21_45" => [
        1547,   # Death Pact                (Cleric   - Divine Intervention)
        3692,   # Temperance                (Cleric   - HP, AC)
        64,     # Resist Magic              (Cleric   - MR)
        3576,   # Blessing of Faith         (Cleric   - Spell Haste)
        2525,   # Harnessing of Spirit      (Shaman   - HP, STR, DEX)
        154,    # Agility                   (Shaman   - AGI)
        389,    # Guardian                  (Shaman   - AC)
        158,    # Stamina                   (Shaman   - STA)
        2524,   # Spirit of Bih`Li          (Shaman   - ATK, Runspeed)
        172,    # Swift Like the Wind       (Enchanter- Haste)
        1694,   # Boon of the Clear Mind    (Enchanter- Mana Regen)
        412,    # Shield of Lava            (Magician - Damage Shield)
        519,    # Thorncoat                 (Druid    - Damage Shield)
        356,    # Shield of Thorns          (Druid    - Damage Shield)
        423,    # Skin Like Nature          (Druid    - HP, AC, HP Regen)
        430,    # Storm Strength            (Druid    - STR)
        2178,   # Spiritual Brawn           (Beastlord- HP, ATK)
        2176,   # Spiritual Light           (Beastlord- HP Regen)
        2596,   # Falcon Eye                (Ranger   - Skills +70%)
        1462,   # Call of Earth             (Ranger   - DS, AC)
    ],
    "46_58" => [
        2122,   # Ancient: Gift of Aegolism         (Cleric   - HP)
        2109,   # Ancient: High Priest's Bulwark    (Cleric   - AC)
        1546,   # Divine Intervention               (Cleric   - DI)
        64,     # Resist Magic                      (Cleric   - MR)
        2530,   # Khura's Focusing                  (Shaman   - HP, STR, DEX)
        1599,   # Voice of the Berserker            (Shaman   - AC, AGI, STR, DEX)
        2529,   # Talisman of Epuration             (Shaman   - PR, DR)
        2528,   # Regrowth of Dar Khura             (Shaman   - HP Regen)
        2570,   # Koadic's Endless Intellect        (Enchanter- Mana Regen, WIS, INT)
        2895,   # Speed of the Brood                (Enchanter- Haste, AGI, AC)
        1669,   # Aegis of Ro                       (Magician - DS)
        3582,   # Elemental Cloak                   (Magician - FR, CR)
        2125,   # Ancient: Legacy of Blades         (Druid    - DS)
        1563,   # Form of the Hunter                (Druid    - Runspeed, ATK, Ultravision)
        1442,   # Protection of the Glades          (Druid    - AC, HP, Mana Regen)
        2630,   # Spiritual Strength                (Beastlord- ATK, HP)
        2629,   # Spiritual Purity                  (Beastlord- Mana Regen, AC)
        2600,   # Warder's Protection               (Ranger   - DS, ATK, AC)
        2599,   # Eagle Eye                         (Ranger   - Skills +80%)
        2590,   # Brell's Mountainous Barrier       (Paladin  - HP)
    ],
    "59_up" => [
        3474,   # Armor of the Zealot       (Cleric   - HP, AC, Mana Regen)
        3479,   # Hand of Virtue            (Cleric   - HP, AC)
        9764,   # Vow of Valor              (Cleric   - Melee Proc)
        4108,   # Aura of Reverence         (Cleric   - Spell Haste)
        1546,   # Divine Intervention       (Cleric   - DI)
        3397,   # Focus of the Seventh      (Shaman   - HP, STR, DEX)
        3389,   # Talisman of the Boar      (Shaman   - STA)
        3384,   # Talisman of the Tribunal  (Shaman   - PR, DR)
        3441,   # Blessing of Replenishment (Shaman   - HP Regen)
        5521,   # Hastening of Salik        (Enchanter- Haste, ATK, AGI, DEX)
        3360,   # Voice of Quellious        (Enchanter- Mana Regen, Mana, INT, WIS)
        3241,   # Night's Dark Terror       (Enchanter- Melee Proc, ATK, DEX)
        3242,   # Guard of Druzzil          (Enchanter- MR)
        3486,   # Maelstrom of Ro           (Magician - DS)
        3329,   # Elemental Barrier         (Magician - FR, CR)
        3451,   # Blessing of the Nine      (Druid    - AC, HP, Mana Regen)
        3295,   # Legacy of Bracken         (Druid    - DS)
        3450,   # Brackencoat               (Druid    - AC, DS)
        3460,   # Spiritual Dominion        (Beastlord- Mana Regen, HP Regen)
        3039,   # Protection of the Wild    (Ranger   - DS, ATK, AC)
        2599,   # Eagle Eye                 (Ranger   - Skills +80%)
        3432,   # Brell's Stalwart Shield   (Paladin  - HP)
        4109,   # Guidance                  (Paladin  - HP, AC)
    ],
);

# Returns the tier key for a level.
sub ShazamTierForLevel {
    my $level = shift;
    foreach my $tier (@SHAZAM_TIERS) {
        return $tier->[0] if $level <= $tier->[1];
    }
    return $SHAZAM_TIERS[-1][0];
}

# Entry point. Returns 1 if $text was a Shazam trigger (handled), 0 otherwise.
sub ShazamBuffs {
    my $client = shift || plugin::val('$client');
    my $text   = shift // plugin::val('$text');

    return 0 unless $client && defined $text && $text =~ $SHAZAM_TRIGGER;

    if ($client->GetBucket($SHAZAM_BUCKET)) {
        my $remaining = $client->GetBucketRemaining($SHAZAM_BUCKET) || $SHAZAM_COOLDOWN;
        $client->Message(15, "The power has not yet gathered again. ($remaining seconds remaining)");
        return 1;
    }

    my $tier  = ShazamTierForLevel($client->GetLevel());
    my $buffs = $SHAZAM_BUFFS{$tier} || [];

    foreach my $spell_id (@$buffs) {
        next unless $spell_id;
        $client->SpellFinished($spell_id, $client);
    }

    # $zone lives in the quest package, not in plugin::, so fetch it the same way
    # $client/$text are fetched above. Skipped in no-levitate zones to avoid the
    # "can't levitate here" spam.
    my $zone = plugin::val('$zone');
    if ($SHAZAM_LEVITATE && $zone && $zone->CanLevitate()) {
        $client->SpellFinished($SHAZAM_LEVITATE, $client);
    }

    $client->SetBucket($SHAZAM_BUCKET, "1", $SHAZAM_COOLDOWN . "s");
    quest::shout2("A crack of thunder echoes as ancient power surges through " . $client->GetCleanName() . "!");
    return 1;
}
