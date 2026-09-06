sub EVENT_TARGET_CHANGE {
	if ($ulevel > 80) {
		if ($status < 80) {
			# Original name, so a Fabled (renamed) Vox is still caught.
			if (plugin::CleanNpcName($client->GetTarget()->GetOrigName()) eq "Lady Vox") {
				quest::ze(0, "I will not fight you, but I will banish you!");
				#:: Move the client to Everfrost Peaks at the specified coordinates
				$client->MovePC(30, -7024, 2020, -60.7, 0);
			}
		}
	}
}
