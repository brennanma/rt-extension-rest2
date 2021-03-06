package RT::Extension::REST2::Util;
use strict;
use warnings;

use JSON ();
use Scalar::Util qw( blessed );

use Sub::Exporter -setup => {
    exports => [qw[
        looks_like_uid
        expand_uid
        expand_uri
        serialize_record
        deserialize_record
        error_as_json
        record_type
        record_class
        escape_uri
        query_string
        custom_fields_for
    ]]
};

sub looks_like_uid {
    my $value = shift;
    return 0 unless ref $value eq 'HASH';
    return 0 unless $value->{type} and $value->{id} and $value->{_url};
    return 1;
}

sub expand_uid {
    my $uid = shift;
       $uid = $$uid if ref $uid eq 'SCALAR';

    return if not defined $uid;

    my $Organization = RT->Config->Get('Organization');
    my ($class, $id) = $uid =~ /^([\w:]+)(?:-\Q$Organization\E)?-(.+)$/g;

    return unless $class and $id;

    $class =~ s/^RT:://;
    $class = lc $class;

    return {
        type    => $class,
        id      => $id,
        _url    => RT::Extension::REST2->base_uri . "/$class/$id",
    };
}

sub expand_uri {
    my $uri = shift;

    return {
        type    => 'external',
        _url    => $uri,
    };
}

sub format_datetime {
    my $sql  = shift;
    my $date = RT::Date->new( RT->SystemUser );
    $date->Set( Format => 'sql', Value => $sql );
    return $date->W3CDTF( Timezone => 'UTC' );
}

sub serialize_record {
    my $record = shift;
    my %data   = $record->Serialize(@_);

    no warnings 'redefine';
    local *RT::Deprecated = sub {
        # don't trigger deprecation warnings for $record->$column below
        # such as RT::Group->Type on 4.2
    };

    for my $column (grep !ref($data{$_}), keys %data) {
        if ($record->_Accessible($column => "read")) {
            # Replace values via the Perl API for consistency, access control,
            # and utf-8 handling.
            $data{$column} = $record->$column;

            # Promote raw SQL dates to a standard format
            if ($record->_Accessible($column => "type") =~ /(datetime|timestamp)/i) {
                $data{$column} = format_datetime( $data{$column} );
            }
        } else {
            delete $data{$column};
        }
    }

    # Replace UIDs with object placeholders
    for my $uid (grep ref eq 'SCALAR', values %data) {
        $uid = expand_uid($uid);
    }

    # Include role members, if applicable
    if ($record->DOES("RT::Record::Role::Roles")) {
        for my $role ($record->Roles(ACLOnly => 0)) {
            my $members = $data{$role} = [];
            my $group = $record->RoleGroup($role);
            my $gm = $group->MembersObj;
            while ($_ = $gm->Next) {
                push @$members, expand_uid($_->MemberObj->Object->UID);
            }

            # Avoid the extra array ref for single member roles
            $data{$role} = shift @$members
                if $group->SingleMemberRoleGroup;
        }
    }

    if (my $cfs = custom_fields_for($record)) {
        my %values;
        while (my $cf = $cfs->Next) {
            my $key    = $cf->Id;
            my $values = $values{$key} ||= [];
            my $ocfvs  = $cf->ValuesForObject( $record );
            my $type   = $cf->Type;
            while (my $ocfv = $ocfvs->Next) {
                my $content = $ocfv->Content;
                if ($type eq 'DateTime') {
                    $content = format_datetime($content);
                }
                elsif ($type eq 'Image' or $type eq 'Binary') {
                    $content = {
                        content_type => $ocfv->ContentType,
                        filename     => $content,
                        _url         => RT::Extension::REST2->base_uri . "/download/cf/" . $ocfv->id,
                    };
                }
                push @$values, $content;
            }
        }

        $data{CustomFields} = \%values;
    }
    return \%data;
}

sub deserialize_record {
    my $record = shift;
    my $data   = shift;

    my $does_roles = $record->DOES("RT::Record::Role::Roles");

    # Sanitize input for the Perl API
    for my $field (sort keys %$data) {
        next if $field eq 'CustomFields';

        my $value = $data->{$field};
        next unless ref $value;
        if (looks_like_uid($value)) {
            # Deconstruct UIDs back into simple foreign key IDs, assuming it
            # points to the same record type (class).
            $data->{$field} = $value->{id} || 0;
        }
        elsif ($does_roles and ($field =~ /^RT::CustomRole-\d+$/ or $record->HasRole($field))) {
            my @members = ref $value eq 'ARRAY'
                ? @$value : $value;

            for my $member (@members) {
                $member = $member->{id} || 0
                    if looks_like_uid($member);
            }
            $data->{$field} = \@members;
        }
        else {
            RT->Logger->debug("Received unknown value via JSON for field $field: ".ref($value));
            delete $data->{$field};
        }
    }
    return $data;
}

sub error_as_json {
    my $response = shift;
    my $return = shift;

    my $body = JSON::encode_json({ message => join "", @_ });

    $response->content_type( "application/json; charset=utf-8" );
    $response->content_length( length $body );
    $response->body( $body );

    return $return;
}

sub record_type {
    my $object = shift;
    my ($type) = blessed($object) =~ /::(\w+)$/;
    return $type;
}

sub record_class {
    my $type = record_type(shift);
    return "RT::$type";
}

sub escape_uri {
    my $uri = shift;
    RT::Interface::Web::EscapeURI(\$uri);
    return $uri;
}

sub query_string {
    my %args = @_;
    my @params;
    for my $key (sort keys %args) {
        my $value = $args{$key};
        next unless defined $value;
        $key = escape_uri($key);
        if (UNIVERSAL::isa($value, 'ARRAY')) {
            push @params,
                map $key ."=". escape_uri($_),
                    map defined $_ ? $_ : '',
                        @$value;
        } else {
            push @params, $key . "=" . escape_uri($value);
        }
    }

    return join '&', @params;
}

sub custom_fields_for {
    my $record = shift;

    # no role yet, but we have registered lookup types
    my %registered_type = map {; $_ => 1 } RT::CustomField->LookupTypes;
    if ($registered_type{$record->CustomFieldLookupType}) {
        # see $HasTxnCFs in /Elements/ShowHistoryPage; seems like it's working
        # around a bug in RT::Transaction->CustomFieldLookupId
        if ($record->isa('RT::Transaction')) {
            my $object = $record->Object;
            if ($object->can('TransactionCustomFields') && $object->TransactionCustomFields->Count) {
                return $object->TransactionCustomFields;
            }
        }
        else {
            return $record->CustomFields;
        }
    }

    return;
}

1;
