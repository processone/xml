all: src

src:
	rebar get-deps compile xref

clean:
	rebar clean

test: all
	rebar -v skip_deps=true eunit

check-syntax:
	gcc -o nul -S ${CHK_SOURCES}

xmlrpc-codec:
	erlc -o tools -I include tools/xml_gen.erl
	erl -noinput +B -pa tools -eval 'case xml_gen:compile("tools/xmlrpc_codec.spec") of ok -> halt(0); _ -> halt(1) end.' 

.PHONY: clean src test all
