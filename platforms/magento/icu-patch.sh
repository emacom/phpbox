for f in vendor/*/framework/View/Element/Html/Calendar.php; do
  [[ -f "$f" ]] || continue
  sed -i -E "s/\\\$localeData\['calendar'\]\['gregorian'\]\['AmPmMarkers'\]\['([01])'\]/(\$localeData['calendar']['gregorian']['AmPmMarkers']['\1'] ?? \$localeData['calendar']['gregorian']['AmPmMarkersAbbr']['\1'] ?? '')/g" "$f"
done
