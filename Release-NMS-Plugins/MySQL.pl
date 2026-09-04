use DBI;
use JSON;

sub LoadMysql {
    my $config = load_config("eqemu_config.json");
    
    # Attempt to connect using 'content_database'
    my $connect = try_connect($config, "content_database");
    
    # If connection to 'content_database' fails, try 'database'
    if (!$connect) {
        $connect = try_connect($config, "database");
    }

    return $connect;
}

sub LoadMysqlServer {
    my $config = load_config("eqemu_config.json");
    
    # Attempt to connect using 'content_database'
    my $connect = try_connect($config, "database");

    return $connect;
}

sub load_config {
    my $config_file = shift;
    open(my $fh, '<', $config_file) or die "cannot open file $config_file"; {
        local $/;
        $content = <$fh>;
    }
    close($fh);
    return JSON->new->decode($content);
}

sub try_connect {
    my ($config, $label) = @_;
    return unless exists $config->{"server"}{$label};
    
    my $db_config = $config->{"server"}{$label};
    my @required_keys = qw(db host username password);
    return unless all_keys_exist($db_config, @required_keys);
    
    # Use the port if it's specified in the config; otherwise, use the default port 3306
    my $port = $db_config->{port} // 3306;

    # Try whichever DBD driver this box actually has.
    #
    # The original code hardcoded "dbi:mysql:", which only DBD::mysql serves. That is a
    # problem on a MariaDB server: DBD::mysql 5.x removed MariaDB support outright
    # (upstream says "use DBD::MariaDB instead") and will not build against MariaDB's
    # client libraries, while DBD::mysql 4.050 - the last version that could - no longer
    # builds on modern Perl. So on MariaDB the only installable driver is DBD::MariaDB,
    # which answers to "dbi:MariaDB:" and not to "dbi:mysql:".
    #
    # Order matters only for speed, not correctness: we ask DBI which drivers are actually
    # present and try those, so a real MySQL box still takes the DBD::mysql path exactly
    # as before. Behaviour is unchanged where DBD::mysql exists.
    my %available = map { $_ => 1 } DBI->available_drivers;
    my @attempts;
    push @attempts, "dbi:mysql:dbname=$db_config->{db};host=$db_config->{host};port=$port"
        if $available{mysql};
    push @attempts, "dbi:MariaDB:database=$db_config->{db};host=$db_config->{host};port=$port"
        if $available{MariaDB};

    unless (@attempts) {
        warn "No Perl DBD driver installed (need DBD::mysql or DBD::MariaDB) - "
           . "item upgrade tiers and progression will not work";
        return;
    }

    my $last_error;
    for my $dsn (@attempts) {
        my $connect = DBI->connect($dsn, $db_config->{username}, $db_config->{password},
            { RaiseError => 0, PrintError => 0 });
        return $connect if $connect;
        $last_error = $DBI::errstr;
    }

    warn "Connection attempt failed for $label: $last_error";
    return;
}

sub all_keys_exist {
    my ($hash_ref, @keys) = @_;
    foreach my $key (@keys) {
        return 0 unless defined $hash_ref->{$key};
    }
    return 1;
}
