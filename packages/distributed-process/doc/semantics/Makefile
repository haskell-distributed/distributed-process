CloudHaskellSemantics.pdf: *.tex *.bib
	pdflatex CloudHaskellSemantics
	bibtex CloudHaskellSemantics
	pdflatex CloudHaskellSemantics
	pdflatex CloudHaskellSemantics

.PHONY: clean
clean:
	rm -f *.aux *.bbl *.blg *.log

# vi:set noexpandtab:
