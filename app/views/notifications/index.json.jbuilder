json.users do
  json.array! @users, :id, :username, :avatar_url
end

# json.cache_collection! @stories do |story|
json.stories @stories do |story|
  json.cache! story do
    json.extract! story, :id, :verb, :subject_type

    json.actor_ids story.activities.map(&:actor_id)
    json.key "Story_#{story.id}"
    json.product_name story.activities.first.try(:target).try(:product).try(:name)
    json.url story_url(story)

    if first_subject = story.activities.first.try(:subject)
      if first_subject.try(:number) && first_subject.try(:title)
        json.subjects do
          json.array! story.activities.map(&:subject), :number, :title
        end
      end
    end

    if target = story.activities.first.try(:target)
      if target.try(:number) && target.try(:title)
        json.target do
          json.number target.try(:number)
          json.title target.try(:title)
        end
      end
    end

    if preview = story.body_preview
      json.body_preview preview.truncate(250).gsub(/\s+\r|\n\s+/, ' ').strip
    end
  end
end