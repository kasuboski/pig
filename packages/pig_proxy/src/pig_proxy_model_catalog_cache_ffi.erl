-module(pig_proxy_model_catalog_cache_ffi).
-export([cached/1, publish/2]).

%% Stable runtime names keep independent deployments' trusted catalogs apart.
cached(Name) -> persistent_term:get({?MODULE, Name}, pig_proxy@model_catalog:empty()).
publish(Name, Catalog) -> persistent_term:put({?MODULE, Name}, Catalog), nil.
