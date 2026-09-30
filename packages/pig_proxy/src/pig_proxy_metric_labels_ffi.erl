-module(pig_proxy_metric_labels_ffi).
-export([configure/1, identities/0]).
%% Only the legacy unscoped emission API reads this default.
configure(Identities) -> persistent_term:put({?MODULE, identities}, Identities), nil.
identities() -> persistent_term:get({?MODULE, identities},
    {identities, fun pig_proxy@model_catalog:empty/0, [], [], [<<>>]}).
