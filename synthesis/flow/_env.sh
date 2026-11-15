# sourced by the flow scripts. Override any of these from the environment.
export PDK=${PDK:-/opt/pdk}
export OPENROAD=${OPENROAD:-/opt/mm/root/envs/pd/bin/openroad}
export OPENSTA=${OPENSTA:-/opt/mm/root/envs/pd/bin/sta}
export FLOWDIR=${FLOWDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
