blacklist.pdf: *.tex *.bib
	pdflatex blacklist
	bibtex blacklist
	pdflatex blacklist
	pdflatex blacklist

.PHONY: clean
clean:
	rm -f *.aux *.bbl *.blg *.log *.pdf 

# vi:set noexpandtab:
